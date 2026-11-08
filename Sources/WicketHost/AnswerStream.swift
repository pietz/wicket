import Foundation
import WicketCore
import os

/// Every AI answer in a frame: provider selection, the messages so far, approvals, Copy/Paste,
/// partial failure, Retry and cancellation. The app makes one (`AppRuntime.live()`) and hands it
/// to Run Agent's runner, which shuts it down. Only an explicit run asks a provider.
@MainActor
public final class AnswerStream {
    /// The settings' `ai.provider`, read when a question is asked; nil for the first ready one.
    public var provider: @MainActor () -> AgentProvider?
    /// What runs are told about Wicket and how their extensions reach review; set by the app.
    public var authoring: ExtensionAuthoring?
    /// A provider's model, effort and speed from settings.json, read when a question is asked; set by
    /// the app. The defaults until it is.
    public var options: @MainActor (AgentProvider) -> AgentOptions = { $0.defaultOptions }
    private let backend: AgentBackend
    /// The runs in flight, each ending once its agent's process tree is gone.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// The approvals shown in frames, by the token their actions carry, until answered or their run ends.
    private var waiting: [String: (run: AgentRun, approval: AgentApproval, draft: AnswerDraft)] = [:]
    /// Runs' conversations, by the token their Follow Up actions carry, newest last. Only the
    /// latest few: Follow Up is offered on answers in the palette, which a dismiss clears.
    private var conversations: [(token: String, conversation: Conversation)] = []
    private var isShutDown = false
    private static let logger = Logger(subsystem: "app.wicket", category: "ai")

    public init(
        backend: AgentBackend = .installed, provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        self.provider = provider
        self.backend = backend
    }

    /// The provider acts in `folder`. With `continuing`, the token of a Follow Up action, it
    /// continues that conversation instead: the agent's own session, with its provider, folder and
    /// settings. With `about`, an extension id (Fix and Change with Agent), the prompt says which
    /// extension it is about, and the run continues the conversation that last built or changed it
    /// (`ExtensionHistory`) unless the invocation asks for a `fresh` one; if that run fails, its page
    /// offers a fresh one.
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
                var startFresh: Item.Action?
                if let extensionID, let authoring {
                    prompt = authoring.about(extensionID) + "\n\n" + prompt
                    if invocation.args?["fresh"] != .bool(true),
                        let remembered = await authoring.extensions.history?.conversation(of: extensionID)
                    {
                        continued = remembered
                        startFresh = Self.fresh(invocation)
                    }
                }
                try await answer(
                    prompt, title: title, invocation: invocation, actingIn: folder, continuing: continued,
                    token: token, startFresh: startFresh, continuation)
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

    /// The invocation again, without the conversation it continued.
    private static func fresh(_ invocation: Invocation) -> Item.Action {
        var args = invocation.args ?? [:]
        args["fresh"] = .bool(true)
        return .run(
            command: invocation.command, text: invocation.text, args: args, title: "Start New Conversation",
            revision: invocation.revision)
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
    /// is the conversation to resume, Follow Up's under `token`; `startFresh` is offered if it fails.
    private func answer(
        _ prompt: String, title: String, invocation: Invocation, actingIn folder: URL?,
        continuing continued: Conversation?, token: String?, startFresh: Item.Action?,
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        let start = ContinuousClock.now
        let provider: AgentProvider
        do {
            provider = try await backend.ready(continued?.provider ?? self.provider()).provider
        } catch {
            var detail = Detail.failure("Run Agent Failed", error.description, command: invocation.command)
            detail.actions = [startFresh, .run(command: .aiSettings, title: "Open AI Settings")].compactMap {
                $0
            }
            output.yield(.show(.detail(detail)))
            return
        }
        try Task.checkCancellation()
        let acting = continued?.folder ?? folder ?? FileManager.default.homeDirectoryForCurrentUser
        let options = continued?.options ?? options(provider)
        let draft = AnswerDraft(
            title: title, invocation: invocation, status: "Asking \(provider.name)…")
        draft.startFresh = startFresh
        output.yield(draft.result)

        // What the extensions folder holds before the run, to offer what it changes for review.
        let before = await authoring?.snapshot()
        let request = AgentRequest(
            prompt: prompt, workingDirectory: acting, options: options,
            instructions: authoring?.instructions(), resume: continued?.session)
        draft.redraw = { output.yield(draft.result) }
        defer { draft.redraw = {} }  // It holds the draft.
        let run = await backend.run(provider, request)
        defer { waiting = waiting.filter { $0.value.draft !== draft } }
        // This run's conversation, once its agent named its session.
        var session: String?
        let conversation = { Conversation(provider: provider, folder: acting, options: options, session: $0) }
        // However this ends (answer, failure, cancellation), it returns only once the agent's
        // process tree is gone, so `shutdown` can wait for it.
        do {
            try await show(
                run, of: provider, in: draft, start: start, extensionsBefore: before,
                session: &session, conversation: conversation, token: token, output)
        } catch let failure as Failure {
            // What a failed or stopped run wrote is offered for review too, once its tree is gone.
            await run.cancelAndWait()
            draft.reviews = await reviews(since: before, conversation: session.flatMap(conversation))
            try Task.checkCancellation()
            draft.failure = failure.description
            output.yield(draft.result)
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
        extensionsBefore: ExtensionAuthoring.Snapshot?, session: inout String?,
        conversation: (String) -> Conversation, token: String?,
        _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        var firstMessage: Duration?
        for await event in run {
            switch event {
            case .session(let id):
                session = id
            case .message(let text):
                firstMessage = firstMessage ?? ContinuousClock.now - start
                draft.add(text)
                draft.redraw()
            case .approvals(let approvals):
                for (token, _) in draft.approvals { waiting[token] = nil }
                draft.show(approvals)
                for (token, approval) in draft.approvals { waiting[token] = (run, approval, draft) }
                draft.redraw()
            case .answer(let answer):
                // The messages stay when they end with this answer; otherwise the answer alone, so
                // the final text is always exactly the answer.
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
                output.yield(draft.result)
                Self.logger.notice(
                    """
                    agent: \(provider.rawValue, privacy: .public) first message after \
                    \(firstMessage.map { "\($0)" } ?? "-", privacy: .public), answer after \
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

    /// Review actions for the extensions the run added or changed since `before`, each of which
    /// remembers `conversation` for Fix and Change with Agent to continue.
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

    /// A run's conversation: the agent's session and the setup a follow-up keeps.
    struct Conversation: Codable {
        var provider: AgentProvider
        var folder: URL
        var options: AgentOptions
        var session: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
