import Foundation
import WicketCore
import os

extension CommandID {
    /// The Extensions list: every discovered extension with its state.
    public static let extensions = CommandID.builtin("extensions")
    /// Checks an extension's current revision and shows the report (args: `id`).
    public static let reviewExtension = CommandID.builtin("review-extension")
    /// Approves a revision that passed a check on a review screen (args: `review`, the token the
    /// screen's Enable action carries).
    public static let enableExtension = CommandID.builtin("enable-extension")
    /// Withdraws an extension's approval (args: `id`).
    public static let disableExtension = CommandID.builtin("disable-extension")
}

/// Wicket's consent screens, one runner behind four built-ins (each its own entry in the app's
/// table, reached by `run` actions on the screens it draws):
///
/// - **Extensions** (`builtin:extensions`): every discovered extension with its state (enabled,
///   problem, changed, not enabled, invalid), then Make a Command. Return on one that isn't enabled
///   reviews it; on an enabled one it shows it.
/// - **Review** (`builtin:review-extension`): an enabled extension's page (run its first command,
///   its secrets, its problems, Use Previous Version, Disable last); otherwise runs the isolated
///   checker on the extension's current sealed revision and shows the report, and only a passing
///   check offers Enable.
/// - **Enable** (`builtin:enable-extension`): approves exactly the revision a screen offered (a
///   review's checked one, or the previous approved one) and closes with a message, or installs
///   and approves a build job's, then reloads its frame, which shows it enabled.
/// - **Disable** (`builtin:disable-extension`): withdraws the approval; its commands leave the
///   palette and its frames stop.
///
/// Enable acts only on a token a screen issued in this run of Wicket: the token is never written
/// anywhere, so a binding in settings.json, a deeplink or another process can't approve anything,
/// and nothing is approved that the user wasn't shown (checked, or approved by them before).
@MainActor
public final class ExtensionsRunner: CommandRunner {
    private let extensions: Extensions
    private let jobs: BuildJobs?
    private let checkOptions: CheckOptions
    /// Revisions a screen offered to enable, by the token its action carries: one that passed a
    /// check on a review screen, or an extension's previous approved one; with the message
    /// enabling it closes with.
    private var offers: [String: (sealed: SealedRevision, message: String)] = [:]

    private static let logger = Logger(subsystem: "app.wicket", category: "consent")

    /// `jobs`' current job can be enabled from its review (Make a Command's frame).
    public init(
        extensions: Extensions, jobs: BuildJobs?,
        checkOptions: CheckOptions = CheckOptions(version: Extensions.hostVersion)
    ) {
        self.extensions = extensions
        self.jobs = jobs
        self.checkOptions = checkOptions
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let task = Task {
            do {
                switch invocation.command {
                case .extensions:
                    continuation.yield(.show(.list(items())))
                case .reviewExtension:
                    try await review(Self.argument("id", of: invocation), continuation)
                case .enableExtension:
                    continuation.yield(try await enable(Self.argument("review", of: invocation)))
                case .disableExtension:
                    continuation.yield(try await disable(Self.argument("id", of: invocation)))
                default:
                    throw Refusal("Nothing runs this command.")
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Review, enable, disable

    /// Shows the extension `id`: enabled already, or its current revision checked, with Enable if
    /// the check passed.
    private func review(_ id: String, _ continuation: AsyncThrowingStream<RunResult, any Error>.Continuation)
        async throws
    {
        guard let found = extensions.discovered.first(where: { $0.id == id }) else {
            throw Refusal("There's no extension \(id) in the extensions folder any more.")
        }
        let current: SealedRevision
        switch found.state {
        case .approved(let sealed):
            continuation.yield(.show(.detail(enabled(sealed, folder: found.folder))))
            return
        case .invalid(let reason, _):
            throw Refusal(reason)
        case .unapproved(let sealed), .changed(_, let sealed):
            current = sealed
        }
        let manifest = current.manifest
        continuation.yield(
            .show(
                .detail(
                    Detail(
                        title: manifest.name, markdown: "_Checking the extension…_",
                        metadata: Self.metadata(current)))))
        let checked = await Checker.check(current, options: checkOptions)
        try Task.checkCancellation()
        Self.logger.notice(
            "review: check \(checked.passed ? "passed" : "failed", privacy: .public), \(checked.report.errors.count, privacy: .public) errors"
        )

        var sections: [String] = []
        if case .changed(let approved, _) = found.state {
            sections.append(
                approved == nil
                    ? "**Changed since it was enabled.** The enabled version is gone, so nothing of it runs until you enable this one."
                    : "**Changed since it was enabled.** The enabled version keeps running until you enable this one."
            )
        }
        if let description = manifest.description { sections.append(description) }
        sections.append("**Commands**\n\n" + Self.commands(manifest))
        sections.append("**Check**\n\n" + Self.report(checked.report))
        var actions: [Item.Action] = []
        if checked.passed {
            actions.append(offer(checked.sealed, message: "Enabled \(manifest.name).", title: "Enable"))
            sections.append(
                manifest.commands.allSatisfy { $0.prompt != nil }
                    ? "_Enable lets these prompts use your AI provider and the inputs listed above. No extension program runs._"
                    : "_Enable runs it with your permissions, as any app you install._")
        } else {
            sections.append("_It can't be enabled until it passes its check._")
        }
        actions.append(.reveal(url: found.folder, title: "Reveal in Finder"))
        continuation.yield(
            .show(
                .detail(
                    Detail(
                        title: manifest.name, markdown: sections.joined(separator: "\n\n"),
                        metadata: Self.metadata(current), actions: actions))))
    }

    /// An action enabling `sealed`, carrying a fresh token only this run of Wicket knows.
    private func offer(_ sealed: SealedRevision, message: String, title: String) -> Item.Action {
        let token = UUID().uuidString
        offers[token] = (sealed, message)
        return .run(command: .enableExtension, args: ["review": .string(token)], title: title)
    }

    /// Approves what the screen that issued `token` offered: a build job's checked revision
    /// (installed first; reloads its frame, which then shows it enabled), or a review's checked
    /// revision or an extension's previous one (closes with a message).
    private func enable(_ token: String) async throws -> RunResult {
        if let job = jobs?.current, job.reviewToken == token {
            try await job.enable(in: extensions)
            guard case .enabled(let sealed, _) = job.phase else {
                throw Refusal("The command wasn't enabled.")
            }
            return .reload(message: "Enabled \(sealed.manifest.name).")
        }
        guard let offer = offers[token] else {
            throw Refusal("This review is no longer current; review the extension again to enable it.")
        }
        offers[token] = nil
        let revision = offer.sealed.revision
        guard extensions.store.retained(revision) != nil else {
            throw Refusal("That version is gone; review the extension again to enable it.")
        }
        try await extensions.approve(revision)
        Self.logger.notice("review: enabled")
        return .close(message: offer.message)
    }

    /// Withdraws the approval of the extension `id`, then closes with a message.
    private func disable(_ id: String) async throws -> RunResult {
        let name =
            extensions.discovered.first { $0.id == id }.flatMap { ($0.sealed ?? $0.approved)?.manifest.name }
            ?? id
        guard extensions.approvals.approved(id) != nil else {
            return .close(message: "\(name) isn't enabled.")
        }
        try await extensions.revoke(id)
        Self.logger.notice("review: disabled")
        return .close(message: "Disabled \(name).")
    }

    private static func argument(_ name: String, of invocation: Invocation) throws -> String {
        guard case .string(let value)? = invocation.args?[name], !value.isEmpty else {
            throw Refusal("Open Extensions to review, enable or disable an extension.")
        }
        return value
    }

    // MARK: What the screens show

    /// The current Make a Command build as the list's first row while it runs, awaits review or
    /// failed; Return shows its frame (`builtin:current-build`). Enabled, it is one of the rows below.
    static func build(_ job: BuildJob?) -> [Item] {
        let state: String
        switch job?.phase {
        case .generating, .checking: state = "Making"
        case .review: state = "Ready for Review"
        case .failed: state = "Failed"
        case .enabled, .cancelled, nil: return []
        }
        return [
            Item(
                id: "extensions:build", title: job?.sentence ?? "", subtitle: "Make a Command",
                icon: .symbol(name: "hammer"), accessory: state,
                actions: [.run(command: .currentBuild, title: "Show Build")])
        ]
    }

    /// The Extensions list: the current build, a damaged approvals file, then each discovered extension in
    /// discovery order (by id), then Make a Command, which is all an empty folder shows.
    private func items() -> [Item] {
        var items = Self.build(jobs?.current)
        if let problem = extensions.approvals.problem {
            items.append(
                Item(
                    id: "extensions:approvals", title: "Approvals Problem", subtitle: problem,
                    icon: .symbol(name: "exclamationmark.triangle"), accessory: "Problem",
                    actions: [.copy(text: problem, title: "Copy Diagnostics")]))
        }
        items += Self.items(extensions.discovered) { self.problems(of: $0) }
        // Opening the folder should work before anything was ever put in it.
        try? FileManager.default.createDirectory(at: extensions.directory, withIntermediateDirectories: true)
        items.append(
            Item(
                id: "extensions:make", title: "Make a Command",
                subtitle: "Describe it in a sentence and your agent builds it", icon: .symbol(name: "hammer"),
                actions: [
                    .run(command: .makeCommand, title: "Make a Command"),
                    .open(url: extensions.directory, title: "Open Extensions Folder"),
                ]))
        return items
    }

    /// The rows of `discovered`; an enabled one with `problems` says so.
    static func items(_ discovered: [DiscoveredExtension], problems: (String) -> [Diagnostic]) -> [Item] {
        discovered.map { found in
            let manifest = (found.sealed ?? found.approved)?.manifest
            let name = manifest?.name ?? found.id
            let reveal = Item.Action.reveal(url: found.folder, title: "Reveal in Finder")
            let review = Item.Action.run(
                command: .reviewExtension, args: ["id": .string(found.id)], title: "Review and Enable")
            let disable = Item.Action.run(
                command: .disableExtension, args: ["id": .string(found.id)], title: "Disable")
            var state: String
            var subtitle = manifest?.description
            var actions: [Item.Action]
            switch found.state {
            case .approved:
                state = "Enabled"
                if let problem = problems(found.id).last {
                    state = "Problem"
                    subtitle = firstLine(problem.text)
                }
                actions = [
                    .run(command: .reviewExtension, args: ["id": .string(found.id)], title: "Show Extension"),
                    reveal, disable,
                ]
            case .changed(let approved, _):
                state = "Changed"
                subtitle = "Changed; review to run the new version"
                actions = approved == nil ? [review, reveal] : [review, reveal, disable]
            case .unapproved:
                state = "Not Enabled"
                actions = [review, reveal]
            case .invalid(let reason, let approved):
                state = "Invalid"
                subtitle = reason
                actions = [.detail(Detail(title: name, markdown: reason, actions: [reveal])), reveal]
                if approved != nil { actions.append(disable) }
            }
            return Item(
                id: "extensions:\(found.id)", title: name, subtitle: subtitle,
                icon: manifest?.icon ?? .symbol(name: "puzzlepiece.extension"), accessory: state,
                actions: actions)
        }
    }

    /// What is wrong with the extension `id` (warnings and errors, its commands' included, such as
    /// a failed run or a keyword another command has), oldest first.
    private func problems(of id: String) -> [Diagnostic] {
        extensions.diagnostics.report(forExtension: id).filter { $0.severity >= .warning }
    }

    /// An enabled extension's page: its commands, the secrets it declares and whether each is set,
    /// and its problems; Return runs its first command, then Reveal in Finder, setting a secret
    /// (one not set first of all), Use Previous Version when the store keeps the one approved
    /// before, Copy Diagnostics when there is anything to copy, and Disable last.
    private func enabled(_ sealed: SealedRevision, folder: URL) -> Detail {
        var detail = Self.enabled(sealed, folder: folder)
        let id = sealed.revision.extensionID
        var extra: [Item.Action] = []
        var sections: [String] = []
        let secrets = sealed.manifest.secrets.map { ($0, extensions.hasSecret($0.name, of: id)) }
        if !secrets.isEmpty {
            sections.append(
                "**Secrets**\n\n"
                    + secrets.map { "- \($0.0.title) (`\($0.0.name)`): \($0.1 ? "Set" : "Not set")" }
                    .joined(separator: "\n"))
            extra += secrets.map { SecretsRunner.action(extension: id, name: $0.0.name) }
        }
        let problems = problems(of: id)
        if !problems.isEmpty {
            sections.append(
                "**Problems**\n\n" + problems.map { "- " + Self.firstLine($0.text) }.joined(separator: "\n"))
        }
        if let previous = extensions.approvals.previous(id), previous != sealed.revision,
            let kept = extensions.store.retained(previous)
        {
            extra.append(
                offer(
                    kept, message: "Now using the previous version of \(kept.manifest.name).",
                    title: "Use Previous Version"))
        }
        let all = extensions.diagnostics.report(forExtension: id)
        if !all.isEmpty {
            extra.append(.copy(text: Self.diagnosticsText(sealed, all), title: "Copy Diagnostics"))
        }
        detail.markdown += sections.map { "\n\n" + $0 }.joined()
        // A secret that isn't set is what the user needs first: the command would only ask for it.
        if let missing = secrets.firstIndex(where: { !$0.1 }) {
            detail.actions.insert(extra.remove(at: missing), at: 0)
        }
        detail.actions.insert(contentsOf: extra, at: detail.actions.count - 1)
        return detail
    }

    /// An enabled extension: its commands; Return runs the first listed one, then Reveal in Finder
    /// and Disable last. What a build's frame shows once it is enabled.
    public static func enabled(_ sealed: SealedRevision, folder: URL) -> Detail {
        let id = sealed.revision.extensionID
        var actions: [Item.Action] = []
        if let first = sealed.manifest.commands.first(where: { !$0.hidden && $0.mode != .root }) {
            actions.append(
                .run(
                    command: .extension(id, first.id), title: "Run \(first.title)", revision: sealed.revision)
            )
        }
        actions.append(.reveal(url: folder, title: "Reveal in Finder"))
        actions.append(.run(command: .disableExtension, args: ["id": .string(id)], title: "Disable"))
        return Detail(
            title: sealed.manifest.name,
            markdown: "**Enabled.** Its commands are in Wicket now:\n\n" + commands(sealed.manifest),
            metadata: metadata(sealed), actions: actions)
    }

    /// Everything the diagnostics hold about an extension, as plain text to paste into a bug
    /// report or an agent's prompt.
    static func diagnosticsText(_ sealed: SealedRevision, _ entries: [Diagnostic]) -> String {
        let header =
            "Wicket diagnostics for \(sealed.manifest.name) (\(sealed.manifest.id) \(sealed.manifest.version), revision \(sealed.revision.sha256.prefix(12)))"
        return
            ([header]
            + entries.map { entry in
                let subject =
                    switch entry.subject {
                    case .command(let command): " \(command.name)"
                    default: ""
                    }
                return "[\(entry.severity)] \(entry.kind)\(subject):\n\(entry.text)"
            }).joined(separator: "\n\n")
    }

    private static func firstLine(_ text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    /// One line per command: its title, keyword and mode.
    static func commands(_ manifest: Manifest) -> String {
        manifest.commands.map { command in
            var line = "- \(command.title)"
            if let keyword = command.keyword { line += ": keyword `\(keyword)`" }
            if command.prompt != nil {
                let placeholders = command.placeholders.map { "{\($0)}" }.joined(separator: ", ")
                line += " (prompt). Uses your AI provider"
                if !placeholders.isEmpty { line += "; reads " + placeholders }
                return line
            }
            return line + " (\(command.mode.rawValue))"
        }.joined(separator: "\n")
    }

    /// One line per line of the check report.
    static func report(_ report: CheckReport) -> String {
        report.lines.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    /// The extension's id, version, revision and capabilities.
    static func metadata(_ sealed: SealedRevision) -> [Detail.Metadata] {
        let capabilities = sealed.manifest.capabilities.map(\.rawValue).joined(separator: ", ")
        return [
            .init(label: "Extension", value: sealed.manifest.id),
            .init(label: "Version", value: sealed.manifest.version),
            .init(label: "Revision", value: String(sealed.revision.sha256.prefix(12))),
            .init(label: "Capabilities", value: capabilities.isEmpty ? "none" : capabilities),
        ]
    }
}
