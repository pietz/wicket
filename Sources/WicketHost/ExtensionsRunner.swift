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
///   changed, not enabled, invalid). Return on one that isn't enabled reviews it; on an enabled one
///   it shows it, with Disable and Reveal in Finder.
/// - **Review** (`builtin:review-extension`): runs the isolated checker on the extension's current
///   sealed revision and shows the report; only a passing check offers Enable.
/// - **Enable** (`builtin:enable-extension`): approves exactly the revision a review screen checked
///   (or installs and approves a build job's), then reloads the review, which shows it enabled.
/// - **Disable** (`builtin:disable-extension`): withdraws the approval; its commands leave the
///   palette and its frames stop.
///
/// Enable acts only on a token a review screen issued in this run of Wicket: the token is never
/// written anywhere, so a binding in settings.json, a deeplink or another process can't approve
/// anything, and nothing is approved without a passing check the user was shown.
@MainActor
public final class ExtensionsRunner: CommandRunner {
    private let extensions: Extensions
    private let jobs: BuildJobs?
    private let checkOptions: CheckOptions
    /// Revisions that passed a check on a review screen, by the token its Enable action carries.
    private var reviews: [String: CheckedRevision] = [:]

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
                    continuation.yield(
                        .show(.list(Self.build(jobs?.current) + Self.items(extensions.discovered))))
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
            continuation.yield(.show(.detail(Self.enabled(sealed, folder: found.folder))))
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
            let token = UUID().uuidString
            reviews[token] = checked
            actions.append(.run(command: .enableExtension, args: ["review": .string(token)], title: "Enable"))
            sections.append("_Enable runs it with your permissions, as any app you install._")
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

    /// Approves what the review that issued `token` checked: a build job's (installed first) or an
    /// extension's current revision. Reloads the review, which then shows it enabled.
    private func enable(_ token: String) async throws -> RunResult {
        if let job = jobs?.current, job.reviewToken == token {
            try await job.enable(in: extensions)
            guard case .enabled(let sealed, _) = job.phase else {
                throw Refusal("The command wasn't enabled.")
            }
            return .reload(message: "Enabled \(sealed.manifest.name).")
        }
        guard let checked = reviews[token] else {
            throw Refusal("This review is no longer current; review the extension again to enable it.")
        }
        let revision = checked.sealed.revision
        guard extensions.store.retained(revision) != nil else {
            reviews[token] = nil
            throw Refusal("The reviewed version is gone; review the extension again to enable it.")
        }
        try await extensions.approve(revision)
        reviews[token] = nil
        Self.logger.notice("review: enabled")
        return .reload(message: "Enabled \(checked.sealed.manifest.name).")
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

    /// The Extensions list's rows, in discovery order (by id).
    static func items(_ discovered: [DiscoveredExtension]) -> [Item] {
        discovered.map { found in
            let manifest = (found.sealed ?? found.approved)?.manifest
            let name = manifest?.name ?? found.id
            let reveal = Item.Action.reveal(url: found.folder, title: "Reveal in Finder")
            let review = Item.Action.run(
                command: .reviewExtension, args: ["id": .string(found.id)], title: "Review and Enable")
            let state: String
            var subtitle = manifest?.description
            var actions: [Item.Action]
            switch found.state {
            case .approved:
                state = "Enabled"
                actions = [
                    .run(command: .reviewExtension, args: ["id": .string(found.id)], title: "Show Extension"),
                    .run(command: .disableExtension, args: ["id": .string(found.id)], title: "Disable"),
                    reveal,
                ]
            case .changed(let approved, _):
                state = "Changed"
                subtitle =
                    approved == nil
                    ? "Changed since it was enabled; review it to run it again"
                    : "Changed since it was enabled; the enabled version runs until you review this one"
                actions = [review, reveal]
                if approved != nil {
                    actions.insert(
                        .run(command: .disableExtension, args: ["id": .string(found.id)], title: "Disable"),
                        at: 1)
                }
            case .unapproved:
                state = "Not Enabled"
                actions = [review, reveal]
            case .invalid(let reason, let approved):
                state = "Invalid"
                subtitle = reason
                actions = [.detail(Detail(title: name, markdown: reason, actions: [reveal])), reveal]
                if approved != nil {
                    actions.append(
                        .run(command: .disableExtension, args: ["id": .string(found.id)], title: "Disable"))
                }
            }
            return Item(
                id: "extensions:\(found.id)", title: name, subtitle: subtitle,
                icon: manifest?.icon ?? .symbol(name: "puzzlepiece.extension"), accessory: state,
                actions: actions)
        }
    }

    /// An enabled extension: its commands, with Disable and Reveal in Finder.
    public static func enabled(_ sealed: SealedRevision, folder: URL) -> Detail {
        Detail(
            title: sealed.manifest.name,
            markdown: "**Enabled.** Its commands are in Wicket now:\n\n" + commands(sealed.manifest),
            metadata: metadata(sealed),
            actions: [
                .run(
                    command: .disableExtension, args: ["id": .string(sealed.revision.extensionID)],
                    title: "Disable"),
                .reveal(url: folder, title: "Reveal in Finder"),
            ])
    }

    /// One line per command: its title, keyword and mode.
    static func commands(_ manifest: Manifest) -> String {
        manifest.commands.map { command in
            var line = "- \(command.title)"
            if let keyword = command.keyword { line += ": keyword `\(keyword)`" }
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
