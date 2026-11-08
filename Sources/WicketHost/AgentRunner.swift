import Foundation
import WicketCore
import os

extension CommandID {
    /// Run Agent: answers a question or does what it asks, the one AI entry.
    public static let runAgent = CommandID.builtin("run-agent")
    /// Opens Settings on its AI pane: the action of a Run Agent frame whose provider isn't ready.
    /// Hidden, reached by id only; the app's table gives it its effect.
    public static let aiSettings = CommandID.builtin("ai-settings")
    /// Answers an acting agent's approval shown in a Run Agent frame (`token` and `decision` args).
    /// Hidden, reached by id only.
    public static let aiApproval = CommandID.builtin("ai-approval")
}

/// How an acting run is set up beyond its prompt: the user's choices for that agent.
public struct AgentConfiguration: Sendable, Equatable {
    public var options: AgentOptions
    public var permission: AgentPermission?

    public init(options: AgentOptions = AgentOptions(), permission: AgentPermission? = nil) {
        self.options = options
        self.permission = permission
    }
}

/// What Run Agent needs from its providers: whether a provider is ready, and an answer run.
/// `installed` uses the CLIs on the login-shell PATH or Apple's model; tests pass stand-ins.
public struct AgentBackend: Sendable {
    public var status: @Sendable (AgentProvider) async -> AgentStatus
    public var run: @Sendable (AgentProvider, AgentRequest) async -> AgentRun

    public init(
        status: @escaping @Sendable (AgentProvider) async -> AgentStatus,
        run: @escaping @Sendable (AgentProvider, AgentRequest) async -> AgentRun
    ) {
        self.status = status
        self.run = run
    }

    public static let installed = AgentBackend(
        status: { await Agent.status(of: $0) },
        run: { provider, request in
            if provider == .apple { return AppleModel.run(request) }
            if let agent = await Agent.locate(provider) { return agent.run(request) }
            let status = AgentStatus(provider: provider, state: .notInstalled)
            return AgentRun {
                $0.yield(.error(status.description))
                return .notRunning
            }
        })
}

/// Run Agent and prompt commands share one answer stream, provider selection and process lifetime.
/// Run Agent acts with a provider that can (`AgentProvider.acts`), in the folder of the Finder
/// selection or the home folder; its approvals are answered through `builtin:ai-approval`. With
/// `authoring`, an acting run knows Wicket and can add or change its commands, and its answer offers
/// to review what it wrote.
@MainActor
public final class AgentRunner: CommandRunner {
    let answers: AnswerStream
    /// Supplies the finished answer's Save as Command action in the app. No action during streaming
    /// or after failure; the saver keeps the original invocation out of action arguments.
    public var saveCommand: (@MainActor (Invocation) -> Item.Action?)?

    public var provider: @MainActor () -> AgentProvider? {
        get { answers.provider }
        set { answers.provider = newValue }
    }

    /// What acting runs are told about Wicket and how their extensions reach review; set by the app.
    public var authoring: ExtensionAuthoring? {
        get { answers.authoring }
        set { answers.authoring = newValue }
    }

    /// How an acting run of a provider runs: settings.json's options and the permission level from
    /// Settings ▸ AI, read when a question is asked; set by the app. Nothing forced by default.
    public var configuration: @MainActor (AgentProvider) -> AgentConfiguration {
        get { answers.configuration }
        set { answers.configuration = newValue }
    }

    public init(
        backend: AgentBackend = .installed, interval: Duration = .milliseconds(33),
        statusLifetime: Duration = .seconds(60), provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        answers = AnswerStream(
            backend: backend, interval: interval,
            statusLifetime: statusLifetime, provider: provider)
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        if invocation.command == .aiApproval { return answers.reply(invocation) }
        let question = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt =
            question.isEmpty
            ? "" : (invocation.context.map { question + "\n\n" + $0.promptBlock } ?? question)
        var submitted = invocation
        submitted.text = question
        // A run started for the user, such as Fix with Agent, can name its frame; else the question does.
        return answers.run(
            submitted, prompt: prompt, title: invocation.args?["title"]?.string ?? question,
            actingIn: Self.folder(for: invocation.context)
        ) { [weak self] in
            self?.saveCommand?(invocation).map { [$0] } ?? []
        }
    }

    /// Where an acting run works: the folder of the Finder selection (a selected folder itself when it
    /// is the only item), else the home folder.
    static func folder(for context: SummonContext?) -> URL {
        guard let files = context?.files, let first = files.first else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return files.count == 1 && isFolder ? first : first.deletingLastPathComponent()
    }

    public func shutdown() async { await answers.shutdown() }
}

/// The shared answer stream: a growing draft, Copy/Paste, partial failure, Retry, throttling and
/// cancellation. Only an explicit run asks a provider. All scratch folders outlive their processes.
@MainActor
final class AnswerStream {
    /// The settings' `ai.provider`, read when a question is asked; nil for the first ready one.
    public var provider: @MainActor () -> AgentProvider?
    /// Tells acting runs about Wicket and finds the extensions they wrote.
    var authoring: ExtensionAuthoring?
    /// The user's model, effort, speed and permission level for an acting run of a provider.
    var configuration: @MainActor (AgentProvider) -> AgentConfiguration = { _ in AgentConfiguration() }
    private let backend: AgentBackend
    private let interval: Duration
    private let statusLifetime: Duration
    /// When each provider was last found ready.
    private var ready: [AgentProvider: ContinuousClock.Instant] = [:]
    /// The runs in flight, each ending once its agent's process tree is gone.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// The approvals shown in frames, by the token their actions carry, until answered or their run ends.
    private var waiting: [String: (run: AgentRun, approval: AgentApproval, draft: Draft)] = [:]
    private var isShutDown = false
    private static let logger = Logger(subsystem: "app.wicket", category: "ai")

    /// `interval` is the shortest time between two shown updates while the answer streams.
    public init(
        backend: AgentBackend = .installed, interval: Duration = .milliseconds(33),
        statusLifetime: Duration = .seconds(60), provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        self.provider = provider
        self.backend = backend
        self.interval = interval
        self.statusLifetime = statusLifetime
    }

    /// With `actingIn`, a provider that acts works in that folder (`AgentMode.act`); otherwise, and
    /// for every other provider, the run only answers, in an empty folder.
    func run(
        _ invocation: Invocation, prompt: String, title: String, actingIn folder: URL? = nil,
        completedActions: @escaping @MainActor () -> [Item.Action] = { [] }
    ) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        guard !isShutDown else {
            continuation.finish(throwing: CancellationError())
            return stream
        }
        let id = UUID()
        let task = Task {
            do {
                guard !prompt.isEmpty else { throw Failure("There's no question to ask.") }
                try await answer(
                    prompt, title: title, invocation: invocation, actingIn: folder,
                    completedActions: completedActions, continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            running[id] = nil
        }
        running[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Answers the approval an `aiApproval` action names, then leaves its frame as it is (`stay`):
    /// the run's own stream shows what happens next. A token that has expired (the question was
    /// answered already, by a fast second Return, or its run ended) changes nothing and stays too,
    /// rather than covering the live answer with a failure.
    func reply(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        AsyncThrowingStream { continuation in
            if case .string(let token)? = invocation.args?["token"],
                case .string(let name)? = invocation.args?["decision"],
                let decision = AgentDecision(rawValue: name),
                let (run, approval, draft) = waiting.removeValue(forKey: token)
            {
                run.reply(to: approval, decision)
                draft.answer(token, approval)
            }
            continuation.yield(.stay)
            continuation.finish()
        }
    }

    /// Ends every run and returns once their agents' process trees are gone; runs asked for after
    /// it fail at once.
    public func shutdown() async {
        isShutDown = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// Asks the prepared prompt; presentation and Retry retain the original invocation.
    private func answer(
        _ prompt: String, title: String, invocation: Invocation, actingIn acting: URL?,
        completedActions: @escaping @MainActor () -> [Item.Action],
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        let start = ContinuousClock.now
        let provider: AgentProvider
        do {
            provider = try await readyProvider()
        } catch {
            var detail = Detail.failure("Run Agent Failed", error.description, command: invocation.command)
            detail.actions = [.run(command: .aiSettings, title: "Open AI Settings")]
            output.yield(.show(.detail(detail)))
            return
        }
        try Task.checkCancellation()
        let acts = acting != nil && provider.acts
        let configuration = acts ? configuration(provider) : AgentConfiguration()
        let draft = Draft(
            title: title, invocation: invocation, status: "Asking \(provider.name)…",
            permission: configuration.permission, completedActions: completedActions)
        output.yield(.show(.detail(draft.detail)))

        let request: AgentRequest
        // What the extensions folder holds before an acting run, to offer what it changes for review.
        var before: ExtensionAuthoring.Snapshot?
        if let acting, acts {
            before = await authoring?.snapshot()
            request = AgentRequest(
                prompt: prompt, workingDirectory: acting, mode: .act, instructions: authoring?.instructions(),
                options: configuration.options, permission: configuration.permission)
        } else {
            // An empty folder, so the agent's working directory holds nothing to read.
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "wicket-ask-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            request = AgentRequest(prompt: prompt, workingDirectory: folder, mode: .answer)
        }
        defer {
            if request.mode == .answer { try? FileManager.default.removeItem(at: request.workingDirectory) }
        }
        let throttle = Throttle(interval: interval) { output.yield(.show(.detail(draft.detail))) }
        draft.redraw = { throttle.submit() }
        defer {
            throttle.cancel()
            draft.redraw = {}  // The throttle's action holds the draft.
        }
        let run = await backend.run(provider, request)
        defer { waiting = waiting.filter { $0.value.draft !== draft } }
        // However this ends (answer, failure, cancellation), it returns only once the agent's
        // process tree is gone, so the folder is removed after it and `shutdown` can wait for it.
        do {
            try await show(
                run, of: provider, in: draft, start: start, throttle: throttle, extensionsBefore: before,
                output)
        } catch let failure as Failure {
            throttle.cancel()
            // What a failed or stopped run wrote is offered for review too, once its tree is gone.
            await run.cancelAndWait()
            draft.reviews = await reviews(since: before)
            try Task.checkCancellation()
            draft.failure = failure.description
            output.yield(.show(.detail(draft.detail)))
            Self.logger.notice(
                "agent: \(provider.rawValue, privacy: .public) failed after \(draft.text.count, privacy: .public) chars"
            )
        } catch {
            await run.cancelAndWait()
            throw error
        }
        await run.cancelAndWait()
    }

    /// Shows the run's events in the frame until its answer, which it returns on, or its error, which
    /// it throws.
    private func show(
        _ run: AgentRun, of provider: AgentProvider, in draft: Draft, start: ContinuousClock.Instant,
        throttle: Throttle, extensionsBefore: ExtensionAuthoring.Snapshot?,
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        var firstText: Duration?
        for await event in run {
            switch event {
            case .text(let delta):
                firstText = firstText ?? ContinuousClock.now - start
                draft.text += delta
                throttle.submit()
            case .activity(let activity):
                draft.progress.append(activity)
                throttle.submit()
            case .acted:
                draft.acted = true
            case .approvals(let approvals):
                for (token, _) in draft.approvals { waiting[token] = nil }
                draft.show(approvals)
                for (token, approval) in draft.approvals { waiting[token] = (run, approval, draft) }
                throttle.submit()
            case .answer(let answer, _):
                throttle.cancel()
                // The final message alone; anything streamed before it (commentary) goes.
                if !answer.isEmpty { draft.text = answer }
                guard !draft.text.isEmpty else { throw Failure("\(provider.name) sent an empty answer.") }
                draft.approvals = []
                // The answer comes once the agent's tree is gone, so what it wrote is complete.
                draft.reviews = await reviews(since: extensionsBefore)
                try Task.checkCancellation()
                // Only a pure answer is a prompt worth saving: not one that made a command, ran one
                // or changed a file.
                draft.finishedActions =
                    draft.reviews.isEmpty && !draft.acted ? draft.completedActions() : []
                output.yield(.show(.detail(draft.detail)))
                Self.logger.notice(
                    """
                    agent: \(provider.rawValue, privacy: .public) first text after \
                    \(firstText.map { "\($0)" } ?? "-", privacy: .public), answer after \
                    \(ContinuousClock.now - start, privacy: .public), \(draft.text.count, privacy: .public) chars
                    """)
                return
            case .error(let message):
                ready[provider] = nil
                throw Failure(message)
            }
        }
        // The agent's stream only ends without a last event when this run was cancelled.
        try Task.checkCancellation()
        throw Failure("\(provider.name) stopped without an answer.")
    }

    /// Review actions for the extensions an acting run added or changed since `before`; none for
    /// answer runs.
    private func reviews(since before: ExtensionAuthoring.Snapshot?) async -> [Item.Action] {
        guard let before, let authoring else { return [] }
        return ExtensionAuthoring.reviews(await authoring.changed(since: before))
    }

    /// The provider to ask, or an error saying why none can answer.
    private func readyProvider() async throws(Failure) -> AgentProvider {
        let chosen = provider()
        var statuses: [AgentStatus] = []
        for candidate in chosen.map({ [$0] }) ?? AgentProvider.allCases {
            if candidate != .apple, let checked = ready[candidate],
                ContinuousClock.now < checked + statusLifetime
            {
                return candidate
            }
            let start = ContinuousClock.now
            let status = await backend.status(candidate)
            Self.logger.notice(
                "agent: \(candidate.rawValue, privacy: .public) status in \(ContinuousClock.now - start, privacy: .public)"
            )
            if status.state == .ready {
                ready[candidate] = .now
                return candidate
            }
            ready[candidate] = nil
            statuses.append(status)
        }
        throw Failure(Self.unavailable(statuses, chosen: chosen != nil, uses: "Run Agent"))
    }

    /// What the frame of `feature` (Run Agent) says when no provider can run it.
    static func unavailable(_ statuses: [AgentStatus], chosen: Bool, uses feature: String) -> String {
        let reasons = statuses.map(reason)
        if chosen, let reason = reasons.first {
            return reason + "\n\nYou can choose another provider in Settings ▸ AI."
        }
        let names = statuses.map { $0.provider.name }.joined(separator: " or ")
        return "\(feature) uses \(names), and none is ready:\n\n"
            + reasons.map { "- \($0)" }.joined(separator: "\n")
    }

    static func reason(_ status: AgentStatus) -> String {
        let provider = status.provider
        return switch status.state {
        case .notInstalled: "\(provider.name) isn't installed: there's no `\(provider.command)` on your PATH."
        case .loggedOut:
            "\(provider.name) isn't signed in: run `\(provider.loginCommand ?? "")` in Terminal to sign in."
        case .unavailable: status.description
        case .ready: "\(provider.name) is ready."
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The answer so far, as the frame shows it.
@MainActor
private final class Draft {
    let title: String
    let invocation: Invocation
    let completedActions: @MainActor () -> [Item.Action]
    var finishedActions: [Item.Action] = []
    /// Reviews of the extensions the run added or changed, first among the finished answer's actions.
    var reviews: [Item.Action] = []
    /// Shown until the first text arrives.
    let status: String
    /// The permission level the run was started with, said under each question; nil when the
    /// agent's own settings decide.
    let permission: AgentPermission?
    var text = ""
    /// What the agent did, one line each ("Ran ls", "Edited notes.md").
    var progress: [String] = []
    /// Whether the agent ran a command or changed a file.
    var acted = false
    /// The agent's questions waiting for the user, oldest first, each with its action token.
    var approvals: [(token: String, approval: AgentApproval)] = []
    /// Approvals the user answered, kept out until the agent confirms them resolved.
    private var answered: Set<JSONValue> = []
    /// Why the run failed, once it has.
    var failure: String?
    /// Shows the latest state; set by the run.
    var redraw: () -> Void = {}

    init(
        title: String, invocation: Invocation, status: String, permission: AgentPermission?,
        completedActions: @escaping @MainActor () -> [Item.Action]
    ) {
        self.title = title
        self.invocation = invocation
        self.status = status
        self.permission = permission
        self.completedActions = completedActions
    }

    /// The agent's waiting approvals, keeping the tokens of those already shown.
    func show(_ waiting: [AgentApproval]) {
        answered.formIntersection(waiting.map(\.id))
        approvals = waiting.filter { !answered.contains($0.id) }.map { approval in
            (approvals.first { $0.approval == approval }?.token ?? UUID().uuidString, approval)
        }
    }

    func answer(_ token: String, _ approval: AgentApproval) {
        answered.insert(approval.id)
        approvals.removeAll { $0.token == token }
        redraw()
    }

    /// The question is the title (the pill shows it), the answer the page, after what the agent did
    /// and, first, the question it is waiting on, whose answers are then the actions. Nothing to act
    /// on until text arrives; a failed run keeps what it sent, marked incomplete, with Retry first.
    var detail: Detail {
        let copy = Item.Action.copy(text: text, title: "Copy Answer")
        guard let failure else {
            let body = text.isEmpty ? "_\(status)_" : text
            if let (token, approval) = approvals.first {
                return Detail(
                    title: title, markdown: ([ask(approval)] + steps + [body]).joined(separator: "\n\n"),
                    actions: [
                        decide(token, .accept, "Allow"),
                        decide(token, .acceptForSession, "Allow for Session"),
                        decide(token, .decline, "Deny"),
                    ])
            }
            let markdown = (steps + [body]).joined(separator: "\n\n")
            if text.isEmpty { return Detail(title: title, markdown: markdown) }
            return Detail(
                title: title, markdown: markdown,
                actions: reviews + [copy, .paste(text: text, title: "Paste Answer")] + finishedActions)
        }
        let retry = Item.Action.run(
            command: invocation.command, text: invocation.text,
            args: invocation.args, title: "Retry", revision: invocation.revision)
        guard !text.isEmpty else {
            var detail = Detail.failure("Run Agent Failed", failure, command: invocation.command)
            detail.actions = reviews + [retry]
            return detail
        }
        return Detail(
            title: title,
            markdown: (steps + [text + "\n\n---\n\n**The answer is incomplete.** " + failure])
                .joined(separator: "\n\n"),
            actions: reviews + [retry, copy])
    }

    /// The progress as a list: the latest steps, and how many came before them.
    private var steps: [String] {
        guard !progress.isEmpty else { return [] }
        let shown = progress.suffix(12)
        let earlier = progress.count - shown.count
        let lines =
            (earlier > 0 ? ["- _\(earlier) earlier steps_"] : []) + shown.map { "- " + Self.escaped($0) }
        return [lines.joined(separator: "\n")]
    }

    private func ask(_ approval: AgentApproval) -> String {
        var parts =
            switch approval.kind {
            case .command:
                [
                    approval.workingDirectory.map {
                        "**The agent asks to run a command** in " + Self.escaped(Self.abbreviated($0)) + "."
                    } ?? "**The agent asks to run a command.**"
                ]
            case .network: ["**The agent asks to reach** " + Self.escaped(approval.subject) + "."]
            case .fileChange: ["**The agent asks to change files:** " + Self.escaped(approval.subject)]
            case .tool: ["**The agent asks to use** " + Self.escaped(approval.subject) + "."]
            }
        if let root = approval.grantRoot {
            parts.append(
                "It asks to write anywhere in " + Self.escaped(Self.abbreviated(root))
                    + " for the rest of this run.")
        }
        if let reason = approval.reason, !reason.isEmpty { parts.append(Self.escaped(reason)) }
        if approval.kind == .command { parts.append(Self.fenced(approval.subject)) }
        if let input = approval.input { parts.append(Self.fenced(input)) }
        if let permission { parts.append("_\(permission.title): \(permission.summary)._") }
        if approvals.count > 1 { parts.append("_\(approvals.count - 1) more waiting_") }
        return parts.joined(separator: "\n\n")
    }

    private func decide(_ token: String, _ decision: AgentDecision, _ title: String) -> Item.Action {
        .run(
            command: .aiApproval, args: ["token": .string(token), "decision": .string(decision.rawValue)],
            title: title)
    }

    /// An absolute path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Text shown as is: Markdown's punctuation escaped.
    static func escaped(_ text: String) -> String {
        text.map { "\\`*_{}[]<>()#+-.!|~&".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    /// A code block that no backtick run inside `code` can close.
    static func fenced(_ code: String) -> String {
        let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + code + "\n" + fence
    }
}

/// Runs `action` at most once per `interval`: at once if the last run is that long ago, else once
/// when the interval is up (however many submits came in between, since it shows the latest state).
@MainActor
private final class Throttle {
    private let interval: Duration
    private let action: @MainActor () -> Void
    private var last: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    init(interval: Duration, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func submit() {
        guard pending == nil else { return }
        guard let last, ContinuousClock.now < last + interval else {
            fire()
            return
        }
        let due = last + interval
        pending = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            fire()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func fire() {
        pending = nil
        last = .now
        action()
    }
}
