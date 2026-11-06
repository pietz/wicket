import Foundation
import Observation
import WicketCore

/// Something wrong (or worth knowing) about one part of Wicket, for the panes, the Extensions screen
/// and later "Fix with agent". Never query text or secret values: Wicket's own texts don't quote
/// queries, and what an extension wrote has its secrets and the run's text redacted first.
public struct Diagnostic: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case `extension`(String)
        case command(CommandID)
        /// settings.json as a whole, or one of its fields.
        case settings
        /// Hotkeys that belong to no command: the palette's own.
        case bindings
    }

    /// Who reports it. Each kind replaces its own reports, so one producer never clears another's.
    public enum Kind: Hashable, Sendable {
        /// A folder in the extensions directory holds no valid extension.
        case discovery
        /// Protocol slips a session recorded, such as a stray stdout line.
        case `protocol`
        /// A setup problem that doesn't stop the extension, such as the Command Line Tools python3.
        case setup
        /// The tail of what the extension wrote to stderr.
        case stderr
        /// The command's last run failed; cleared by its next answer.
        case run
        /// A hotkey or alias from settings.json that isn't in effect.
        case binding
        /// A keyword another command has.
        case conflict
        /// A field of settings.json that was ignored, or a file that couldn't be read.
        case settings
    }

    public enum Severity: Int, Comparable, Sendable {
        case info, warning, error

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var subject: Subject
    public var kind: Kind
    public var severity: Severity
    public var text: String
    /// When it was first reported; an unchanged report keeps its time.
    public var at: Date

    public init(_ subject: Subject, _ kind: Kind, _ severity: Severity, _ text: String, at: Date = .now) {
        self.subject = subject
        self.kind = kind
        self.severity = severity
        self.text = text
        self.at = at
    }

    /// Whether it is about the extension `id`: the extension itself or one of its commands.
    public func concerns(extension id: String) -> Bool {
        switch subject {
        case .extension(let other): other == id
        case .command(let command): command.owner == .extension(id: id)
        case .settings, .bindings: false
        }
    }
}

/// Every diagnostic Wicket holds, from every producer: extension discovery, sessions (protocol
/// issues, setup warnings, the stderr tail), failed runs (root searches and command frames alike),
/// hotkey and alias bindings, keyword conflicts, and settings.json. Producers replace their own
/// reports (`set`, `replace`); readers ask by subject (`entries(for:)`, `text(for:kind:)`) or for one
/// extension's whole picture (`report(forExtension:)`).
///
/// Bounded: each subject keeps at most `perKind` reports of each kind (the newest), and each text
/// at most `textLimit` bytes (a stderr tail `stderrLimit`, its end kept on a line boundary).
@MainActor
@Observable
public final class Diagnostics {
    public nonisolated static let perKind = 10
    public nonisolated static let textLimit = 4 << 10
    public nonisolated static let stderrLimit = 16 << 10

    /// Oldest first.
    public private(set) var all: [Diagnostic] = []

    public init() {}

    /// What is reported about `subject`, oldest first.
    public func entries(for subject: Diagnostic.Subject) -> [Diagnostic] {
        all.filter { $0.subject == subject }
    }

    /// What `kind` reports about `subject`, joined into one line; nil if nothing.
    public func text(for subject: Diagnostic.Subject, kind: Diagnostic.Kind) -> String? {
        let texts = all.filter { $0.subject == subject && $0.kind == kind }.map(\.text)
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    /// Everything about the extension `id` and its commands, oldest first: what the Extensions
    /// screen shows and "Fix with agent" hands over.
    public func report(forExtension id: String) -> [Diagnostic] {
        all.filter { $0.concerns(extension: id) }
    }

    /// Replaces what `kind` says about `subject` with `texts` (an empty list clears it).
    public func set(
        _ kind: Diagnostic.Kind, of subject: Diagnostic.Subject, _ severity: Diagnostic.Severity,
        _ texts: [String]
    ) {
        update(
            removing: { $0.subject == subject && $0.kind == kind },
            adding: texts.map { Diagnostic(subject, kind, severity, $0) })
    }

    /// Replaces everything `kind` says, about any subject, with `diagnostics` (each of that kind):
    /// for producers that report all their subjects at once, such as bindings after a settings
    /// reload.
    public func replace(_ kind: Diagnostic.Kind, with diagnostics: [Diagnostic]) {
        precondition(diagnostics.allSatisfy { $0.kind == kind })
        update(removing: { $0.kind == kind }, adding: diagnostics)
    }

    /// Drops every report `shouldRemove` names, such as an extension's when it is removed.
    public func remove(where shouldRemove: (Diagnostic) -> Bool) {
        update(removing: shouldRemove, adding: [])
    }

    /// One change. A report made again keeps its time (and so its place, `all` being ordered by
    /// time), and `all` is assigned only if something changed, so a producer repeating itself
    /// causes no churn.
    private func update(removing shouldRemove: (Diagnostic) -> Bool, adding new: [Diagnostic]) {
        let removed = all.filter(shouldRemove)
        var counts: [Key: Int] = [:]
        // The newest `perKind` of each subject and kind.
        let added = new.reversed().filter { diagnostic in
            let key = Key(subject: diagnostic.subject, kind: diagnostic.kind)
            counts[key, default: 0] += 1
            return counts[key, default: 0] <= Self.perKind
        }.reversed().map { diagnostic in
            var diagnostic = diagnostic
            diagnostic.text = Self.bound(diagnostic.text, kind: diagnostic.kind)
            if let old = removed.first(where: { $0.same(as: diagnostic) }) { diagnostic.at = old.at }
            return diagnostic
        }
        let next = (all.filter { !shouldRemove($0) } + added).enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        if next != all { all = next }
    }

    private struct Key: Hashable {
        let subject: Diagnostic.Subject
        let kind: Diagnostic.Kind
    }

    /// A text within its limit (by default its kind's): a stderr tail keeps its end from a line
    /// start, so no cut-off secret survives redaction; anything else keeps its beginning.
    nonisolated static func bound(_ text: String, kind: Diagnostic.Kind, limit: Int? = nil) -> String {
        let limit = limit ?? (kind == .stderr ? stderrLimit : textLimit)
        let utf8 = text.utf8
        guard utf8.count > limit else { return text }
        if kind == .stderr {
            let tail = utf8.suffix(limit)
            let start =
                tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
            return String(decoding: tail[start...], as: UTF8.self)
        }
        return String(decoding: utf8.prefix(limit), as: UTF8.self) + "…"
    }
}

extension Diagnostic {
    /// The same report, whenever it was made.
    fileprivate func same(as other: Diagnostic) -> Bool {
        subject == other.subject && kind == other.kind && severity == other.severity && text == other.text
    }
}

/// Redaction for text an extension wrote before it becomes a diagnostic.
enum Redaction {
    /// `text` with every value of `secrets` and, if it is at least 3 characters (shorter would blank
    /// out ordinary words), the run's `query` replaced. Secrets shorter than 4 characters are not
    /// tokens anyone would store; they are left alone for the same reason.
    static func redact(_ text: String, secrets: some Sequence<String>, query: String? = nil) -> String {
        var text = text
        for secret in secrets where secret.count >= 4 {
            text = text.replacingOccurrences(of: secret, with: "‹secret›")
        }
        if let query, query.count >= 3 {
            text = text.replacingOccurrences(of: query, with: "‹query›")
        }
        return text
    }
}
