import Foundation
import WicketCore
import os

/// What Wicket remembers about each extension besides its code, so a failure can be debugged after
/// the fact and the agent that built it can be asked again: its recent runs, and the agent
/// conversation that last built or changed it. One folder per extension under
/// `ExtensionPaths.history` (`<id>/runs.jsonl`, `<id>/conversation.json`), never in the extension's
/// own folder, which is sealed and hashed. It stays on this Mac, is never logged, and Move to Trash
/// deletes it (`forget`).
///
/// A run records what is needed to tell what happened and to reproduce it: when, the revision, the
/// command, the outcome and why, how long it took, and the stderr tail (secrets redacted). The text and args it was sent are kept for failed runs only: a failure often depends on
/// the input ("Berlin" works, "" doesn't), while a successful run's input helps no one, and a live
/// command is sent every keystroke. Consecutive successful runs of one command and revision fold
/// into one entry with a count, so a burst of searches never pushes a failure out.
public actor ExtensionHistory {
    /// How a run ended.
    public enum Outcome: String, Codable, Sendable {
        /// It answered.
        case ok
        /// It answered with an error of its own.
        case error
        /// It answered, and Wicket rejected the answer (not valid by the protocol, or too long).
        case rejected
        /// Wicket didn't run it, or stopped it: not enabled, changed since shown, a secret missing.
        case refused
        /// It couldn't start, or exited before answering.
        case crashed
        /// It didn't answer in time.
        case timeout

        /// How `error`, thrown by a run, ended it.
        public init(_ error: any Error) {
            switch error {
            case is ExtensionError: self = .error
            case HostError.invalidResponse, HostError.outputTooLong: self = .rejected
            case HostError.timeout: self = .timeout
            case HostError.exited, HostError.exitedAfterAnswering, HostError.launch: self = .crashed
            default: self = .refused
            }
        }

        /// Whether the extension's own code went wrong, so changing it can fix it; a refusal is
        /// Wicket's doing (not enabled, changed since shown, a secret to set).
        public var isFixable: Bool { self != .ok && self != .refused }
    }

    /// One run, or several successful ones in a row (`count`).
    public struct Run: Codable, Sendable, Equatable {
        /// When it ended (the last of a folded run).
        public var time: Date = .now
        /// The revision that ran, its first 12 hex digits; nil if none was bound.
        public var revision: String?
        public var command: String
        public var outcome: Outcome
        public var milliseconds: Int
        /// How many successful runs in a row this entry stands for; nil for one.
        public var count: Int?
        /// Why it failed, secrets redacted.
        public var message: String?
        /// What it was sent; failed runs only.
        public var text: String?
        public var args: [String: JSONValue]?
        /// The end of what the extension wrote to stderr when it failed, redacted.
        public var stderr: String?
    }

    public nonisolated static let runLimit = 50
    public nonisolated static let byteLimit = 128 << 10
    static let messageLimit = 2 << 10
    static let stderrLimit = 2 << 10
    static let textLimit = 500
    static let argsLimit = 1 << 10

    public nonisolated let root: URL
    /// Each extension's runs as last read or written, oldest first: Wicket is the only writer.
    private var cache: [String: [Run]] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// The extension `id`'s folder; nil for anything that isn't an extension id, so a name from the
    /// command line can't reach outside `root`.
    public nonisolated func folder(of id: String) -> URL? {
        Manifest.isSlug(id) ? root.appending(path: id, directoryHint: .isDirectory) : nil
    }

    // MARK: Runs

    /// Adds `run` to the extension `id`'s history: folded into the newest entry if both are
    /// successful runs of one command and revision, else appended; then the oldest go beyond
    /// `runLimit` entries or `byteLimit` bytes. A write that fails loses only this entry.
    public func record(_ run: Run, of id: String) {
        guard let file = folder(of: id)?.appending(path: "runs.jsonl") else { return }
        var runs = runs(of: id)
        var run = run
        if run.outcome == .ok {
            run.message = nil
            run.text = nil
            run.args = nil
            run.stderr = nil
        } else {
            run.message = run.message.map { Diagnostics.bound($0, limit: Self.messageLimit) }
            run.stderr = run.stderr.map { Diagnostics.bound($0, limit: Self.stderrLimit, tail: true) }
                .flatMap { $0.isEmpty ? nil : $0 }
            run.text = run.text.map { $0.count > Self.textLimit ? $0.prefix(Self.textLimit) + "…" : $0 }
            if let args = run.args, (try? JSONEncoder().encode(args))?.count ?? .max > Self.argsLimit {
                run.args = nil
            }
        }
        if let last = runs.last, last.outcome == .ok, run.outcome == .ok, last.command == run.command,
            last.revision == run.revision
        {
            run.count = (last.count ?? 1) + 1
            runs[runs.count - 1] = run
        } else {
            runs.append(run)
        }
        let encoder = Self.encoder
        var lines = runs.suffix(Self.runLimit).compactMap { try? encoder.encode($0) }
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 1 }) > Self.byteLimit {
            lines.removeFirst()
        }
        cache[id] = lines.compactMap { try? Self.decoder.decode(Run.self, from: $0) }
        var data = Data()
        for line in lines { data.append(line + [UInt8(ascii: "\n")]) }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The extension `id`'s recorded runs, oldest first; lines that can't be read are skipped.
    public func runs(of id: String) -> [Run] {
        if let cached = cache[id] { return cached }
        guard let file = folder(of: id)?.appending(path: "runs.jsonl"),
            let data = try? Data(contentsOf: file)
        else { return [] }
        let runs = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? Self.decoder.decode(Run.self, from: $0)
        }
        cache[id] = runs
        return runs
    }

    /// The failed runs among the newest `window` that changing the extension could fix, oldest
    /// first: what Fix with Agent hands over, and whether an extension's page offers it.
    public func recentFailures(of id: String, window: Int = 10) -> [Run] {
        runs(of: id).suffix(window).filter { $0.outcome.isFixable }
    }

    /// The newest run of `revision` of each command whose newest run of it failed in a way changing
    /// the extension could fix, oldest first: what is wrong with that revision's runs right now.
    public func failing(_ revision: ExtensionRevision) -> [Run] {
        let hash = String(revision.sha256.prefix(12))
        var newest: [String: Run] = [:]
        for run in runs(of: revision.extensionID) where run.revision == hash { newest[run.command] = run }
        return newest.values.filter(\.outcome.isFixable).sorted { $0.time < $1.time }
    }

    // MARK: The build conversation

    /// Remembers `conversation` as the one that last built or changed the extension `id`,
    /// replacing any before it.
    func remember(_ conversation: AgentRunner.Conversation, for id: String) {
        guard let file = folder(of: id)?.appending(path: "conversation.json"),
            let data = try? Self.encoder.encode(conversation)
        else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The conversation that last built or changed the extension `id`, if one is remembered. One
    /// this build can't read (an older shape) counts as none.
    func conversation(of id: String) -> AgentRunner.Conversation? {
        guard let file = folder(of: id)?.appending(path: "conversation.json"),
            let data = try? Data(contentsOf: file)
        else { return nil }
        guard let conversation = try? Self.decoder.decode(AgentRunner.Conversation.self, from: data) else {
            Self.logger.notice("history: 1 unreadable conversation, ignored")
            return nil
        }
        return conversation
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "history")

    /// Deletes everything remembered about the extension `id`: for Move to Trash.
    public func forget(_ id: String) {
        cache[id] = nil
        guard let folder = folder(of: id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: As text

    /// `runs` as `wicket log` prints them and Fix with Agent hands them over: one line per entry
    /// (time, command, outcome, duration, revision), then a failure's message, text, args and stderr
    /// tail, indented.
    public nonisolated static func text(_ runs: [Run]) -> String {
        runs.map { run in
            var line =
                "\(run.time.formatted(timeStyle)) \(run.command) \(run.outcome.rawValue) in \(run.milliseconds) ms"
            if let count = run.count { line += " (\(count) runs in a row)" }
            if let revision = run.revision { line += ", revision \(revision)" }
            var lines = [line]
            if let message = run.message { lines.append(indented("message: " + message)) }
            if let text = run.text { lines.append(indented("text: " + quoted(text))) }
            if let args = run.args, let json = try? encoder.encode(args) {
                lines.append(indented("args: " + String(decoding: json, as: UTF8.self)))
            }
            if let stderr = run.stderr {
                lines.append(indented("stderr:"))
                lines.append(indented(stderr.trimmingCharacters(in: .newlines), by: "    "))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private nonisolated static func indented(_ text: String, by prefix: String = "  ") -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(
            separator: "\n")
    }

    private nonisolated static func quoted(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? text
    }

    private nonisolated static let timeStyle = Date.ISO8601FormatStyle(
        dateTimeSeparator: .space, timeZone: .current)

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
