import Foundation
import WicketCore
import os

/// Every AI answer in a frame: provider selection, a growing draft, approvals, Copy/Paste, partial
/// failure, Retry, throttling and cancellation. The app makes one (`AppRuntime.live()`) and hands it
/// to Run Agent's runner, which shuts it down. Only an explicit run asks a provider.
@MainActor
public final class AnswerStream {
    /// The settings' `ai.provider`, read when a question is asked; nil for the first ready one.
    public var provider: @MainActor () -> AgentProvider?
    /// What acting runs are told about Wicket and how their extensions reach review; set by the app.
    public var authoring: ExtensionAuthoring?
    /// How an acting run of a provider runs: settings.json's options and the permission level from
    /// Settings ▸ AI, read when a question is asked; set by the app. The defaults until it is.
    public var configuration: @MainActor (AgentProvider) -> AgentConfiguration = {
        AgentConfiguration(options: $0.defaultOptions, permission: .auto)
    }
    /// The settings' `ai.streamAnswers`, read when a question is asked: whether text is drawn as it
    /// comes, or each message only once it is whole.
    public var streamsAnswers: @MainActor () -> Bool = { false }
    private let backend: AgentBackend
    private let interval: Duration
    /// The runs in flight, each ending once its agent's process tree is gone.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// The approvals shown in frames, by the token their actions carry, until answered or their run ends.
    private var waiting: [String: (run: AgentRun, approval: AgentApproval, draft: AnswerDraft)] = [:]
    /// Acting runs' conversations, by the token their Follow Up actions carry, newest last. Only the
    /// latest few: Follow Up is offered on answers in the palette, which a dismiss clears.
    private var conversations: [(token: String, conversation: Conversation)] = []
    private var isShutDown = false
    private static let logger = Logger(subsystem: "app.wicket", category: "ai")

    /// `interval` is the shortest time between two shown updates while the answer streams.
    public init(
        backend: AgentBackend = .installed, interval: Duration = .milliseconds(33),
        provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        self.provider = provider
        self.backend = backend
        self.interval = interval
    }

    /// The provider acts in `folder` (`AgentMode.act`). With `continuing`, the token of a Follow Up
    /// action, it continues that conversation instead: the agent's own session, with its provider,
    /// folder and settings.
    /// With `about`, an extension id (Fix and Change with Agent), the prompt is prefixed with which
    /// extension it is about, and the run continues the conversation that last built or changed it
    /// (`ExtensionHistory`), or starts a new one if there is none or it can't be resumed.
    func run(
        _ invocation: Invocation, prompt: String, title: String, actingIn folder: URL? = nil,
        continuing token: String? = nil, about extensionID: String? = nil
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
                var prompt = prompt
                var continued: Conversation?
                if let token {
                    continued = conversations.last { $0.token == token }?.conversation
                    guard continued != nil else {
                        throw Failure("This conversation has ended. Ask again to start a new one.")
                    }
                }
                var remembered: Conversation?
                if let extensionID, let authoring {
                    prompt = authoring.about(extensionID) + "\n\n" + prompt
                    remembered = await authoring.extensions.history?.conversation(of: extensionID)
                    // The permission level is consent: always the one the user has chosen now.
                    if let provider = remembered?.provider {
                        remembered?.configuration.permission = configuration(provider).permission
                    }
                }
                do {
                    try await answer(
                        prompt, title: title, invocation: invocation, actingIn: folder,
                        continuing: continued ?? remembered, token: token,
                        resumable: continued == nil && remembered != nil, continuation)
                } catch is ResumeFailed {
                    Self.logger.notice(
                        "agent: the extension's conversation couldn't be resumed; starting anew")
                    try await answer(
                        prompt, title: title, invocation: invocation, actingIn: folder, continuing: nil,
                        token: nil, resumable: false, continuation)
                }
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

    /// Asks the prepared prompt; presentation and Retry retain the original invocation. `continued`
    /// is the conversation to resume, Follow Up's under `token`; when `resumable` (an extension's
    /// remembered one), a resume that can't start or fails before the agent writes or does anything
    /// throws `ResumeFailed`, for a new conversation to be started instead.
    private func answer(
        _ prompt: String, title: String, invocation: Invocation, actingIn folder: URL?,
        continuing continued: Conversation?, token: String?, resumable: Bool,
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        let start = ContinuousClock.now
        let provider: AgentProvider
        do {
            provider = try await backend.ready(continued?.provider ?? self.provider()).provider
        } catch {
            if resumable { throw ResumeFailed() }
            var detail = Detail.failure("Run Agent Failed", error.description, command: invocation.command)
            detail.actions = [.run(command: .aiSettings, title: "Open AI Settings")]
            output.yield(.show(.detail(detail)))
            return
        }
        try Task.checkCancellation()
        let acting = continued?.folder ?? folder ?? FileManager.default.homeDirectoryForCurrentUser
        let configuration = continued?.configuration ?? configuration(provider)
        let draft = AnswerDraft(
            title: title, invocation: invocation, status: "Asking \(provider.name)…",
            permission: configuration.permission, streams: streamsAnswers())
        output.yield(.show(.detail(draft.detail)))

        // What the extensions folder holds before the run, to offer what it changes for review.
        let before = await authoring?.snapshot()
        let request = AgentRequest(
            prompt: prompt, workingDirectory: acting, mode: .act(configuration),
            instructions: authoring?.instructions(), resume: continued?.session)
        let throttle = Throttle(interval: interval) { output.yield(.show(.detail(draft.detail))) }
        draft.redraw = { throttle.submit() }
        defer {
            throttle.cancel()
            draft.redraw = {}  // The throttle's action holds the draft.
        }
        let run = await backend.run(provider, request)
        defer { waiting = waiting.filter { $0.value.draft !== draft } }
        // This run's conversation, once its agent named its session.
        var session: String?
        let conversation = { (session: String) -> Conversation? in
            Conversation(provider: provider, folder: acting, configuration: configuration, session: session)
        }
        // However this ends (answer, failure, cancellation), it returns only once the agent's
        // process tree is gone, so `shutdown` can wait for it.
        do {
            try await show(
                run, of: provider, in: draft, start: start, throttle: throttle, extensionsBefore: before,
                session: &session, conversation: conversation, token: token, output)
        } catch let failure as Failure {
            throttle.cancel()
            // What a failed or stopped run wrote is offered for review too, once its tree is gone.
            await run.cancelAndWait()
            if resumable, draft.text.isEmpty, !draft.acted { throw ResumeFailed() }
            draft.reviews = await reviews(since: before, conversation: session.flatMap(conversation))
            try Task.checkCancellation()
            draft.endMessage()
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
        _ run: AgentRun, of provider: AgentProvider, in draft: AnswerDraft, start: ContinuousClock.Instant,
        throttle: Throttle, extensionsBefore: ExtensionAuthoring.Snapshot?, session: inout String?,
        conversation: (String) -> Conversation?, token: String?,
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        var firstText: Duration?
        for await event in run {
            switch event {
            case .session(let id):
                session = id
            case .text(let delta):
                firstText = firstText ?? ContinuousClock.now - start
                if draft.write(delta) { throttle.submit() }
            case .messageEnd:
                draft.endMessage()
                throttle.submit()
            case .activity:
                break  // Tool use isn't shown; only what the agent writes.
            case .acted:
                draft.acted = true
            case .approvals(let approvals):
                for (token, _) in draft.approvals { waiting[token] = nil }
                draft.show(approvals)
                for (token, approval) in draft.approvals { waiting[token] = (run, approval, draft) }
                throttle.submit()
            case .answer(let answer, _):
                throttle.cancel()
                draft.endMessage()
                // What streamed stays when it ends with this answer (messages along the way, then the
                // answer); otherwise the answer alone, so the final text is always exactly the answer.
                if !answer.isEmpty {
                    draft.answer = answer
                    if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(
                        answer.trimmingCharacters(in: .whitespacesAndNewlines))
                    {
                        draft.text = answer
                    }
                }
                guard !draft.text.isEmpty else { throw Failure("\(provider.name) sent an empty answer.") }
                draft.approvals = []
                // The answer comes once the agent's tree is gone, so what it wrote is complete.
                let conversation = session.flatMap(conversation)
                draft.reviews = await reviews(since: extensionsBefore, conversation: conversation)
                try Task.checkCancellation()
                // Follow Up continues this conversation, under the token its follow-ups keep.
                draft.followUp = conversation.map { remember($0, as: token ?? UUID().uuidString) }
                output.yield(.show(.detail(draft.detail)))
                Self.logger.notice(
                    """
                    agent: \(provider.rawValue, privacy: .public) first text after \
                    \(firstText.map { "\($0)" } ?? "-", privacy: .public), answer after \
                    \(ContinuousClock.now - start, privacy: .public), \(draft.text.count, privacy: .public) chars
                    """)
                return
            case .error(let message):
                throw Failure(message)
            }
        }
        // The agent's stream only ends without a last event when this run was cancelled.
        try Task.checkCancellation()
        throw Failure("\(provider.name) stopped without an answer.")
    }

    /// Keeps `conversation` under `token` (replacing what it held, dropping the oldest beyond
    /// `keptConversations`) and returns the Follow Up action that continues it.
    private func remember(_ conversation: Conversation, as token: String) -> Item.Action {
        conversations.removeAll { $0.token == token }
        conversations.append((token, conversation))
        conversations.removeFirst(max(0, conversations.count - Self.keptConversations))
        return .run(command: .followUp, args: ["conversation": .string(token)], title: "Follow Up")
    }

    /// Review actions for the extensions the run added or changed since `before`. Each such extension remembers `conversation` as the one that built it, which
    /// Fix and Change with Agent continue.
    private func reviews(since before: ExtensionAuthoring.Snapshot?, conversation: Conversation?) async
        -> [Item.Action]
    {
        guard let before, let authoring else { return [] }
        let changed = await authoring.changed(since: before)
        if let conversation, let history = authoring.extensions.history {
            for found in changed { await history.remember(conversation, for: found.id) }
        }
        return ExtensionAuthoring.reviews(changed)
    }

    /// How many conversations Follow Up can continue.
    static let keptConversations = 20

    /// An acting run's conversation: the agent's own session and what the run was set up with, which
    /// a follow-up keeps.
    struct Conversation: Codable {
        var provider: AgentProvider
        var folder: URL
        var configuration: AgentConfiguration
        var session: String
    }

    /// An extension's remembered conversation couldn't be resumed; a new one starts instead.
    private struct ResumeFailed: Error {}

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
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
