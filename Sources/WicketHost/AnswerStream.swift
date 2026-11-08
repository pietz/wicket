import Foundation
import WicketCore
import os

/// Every AI answer in a frame, Run Agent's and prompt commands': provider selection, a growing
/// draft, approvals, Copy/Paste, partial failure, Retry, throttling and cancellation. The app makes
/// one (`AppRuntime.live()`) and hands it to Run Agent's runner, which shuts it down, and to
/// `Extensions` for prompt commands. Only an explicit run asks a provider; every scratch folder
/// outlives its process.
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
    private let backend: AgentBackend
    private let interval: Duration
    /// The runs in flight, each ending once its agent's process tree is gone.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// The approvals shown in frames, by the token their actions carry, until answered or their run ends.
    private var waiting: [String: (run: AgentRun, approval: AgentApproval, draft: AnswerDraft)] = [:]
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

    /// With `actingIn`, the provider acts in that folder (`AgentMode.act`); otherwise the run only
    /// answers, in an empty folder.
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
            provider = try await backend.ready(self.provider()).provider
        } catch {
            var detail = Detail.failure("Run Agent Failed", error.description, command: invocation.command)
            detail.actions = [.run(command: .aiSettings, title: "Open AI Settings")]
            output.yield(.show(.detail(detail)))
            return
        }
        try Task.checkCancellation()
        let configuration = acting.map { _ in configuration(provider) }
        let draft = AnswerDraft(
            title: title, invocation: invocation, status: "Asking \(provider.name)…",
            permission: configuration?.permission, completedActions: completedActions)
        output.yield(.show(.detail(draft.detail)))

        let request: AgentRequest
        // What the extensions folder holds before an acting run, to offer what it changes for review.
        var before: ExtensionAuthoring.Snapshot?
        if let acting, let configuration {
            before = await authoring?.snapshot()
            request = AgentRequest(
                prompt: prompt, workingDirectory: acting, mode: .act(configuration),
                instructions: authoring?.instructions())
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
        _ run: AgentRun, of provider: AgentProvider, in draft: AnswerDraft, start: ContinuousClock.Instant,
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
