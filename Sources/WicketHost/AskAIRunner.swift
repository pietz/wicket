import Foundation
import WicketCore
import os

/// What Ask AI needs from the agent CLIs: whether a provider is ready, and an answer run.
/// `installed` uses the CLIs on the login-shell PATH; tests pass stand-ins.
public struct AgentBackend: Sendable {
    public var status: @Sendable (AgentProvider) async -> AgentStatus
    public var run: @Sendable (AgentProvider, AgentRequest) async -> AsyncStream<AgentEvent>

    public init(
        status: @escaping @Sendable (AgentProvider) async -> AgentStatus,
        run: @escaping @Sendable (AgentProvider, AgentRequest) async -> AsyncStream<AgentEvent>
    ) {
        self.status = status
        self.run = run
    }

    public static let installed = AgentBackend(
        status: { await Agent.status(of: $0) },
        run: { provider, request in
            if let agent = await Agent.locate(provider) { return agent.run(request) }
            let status = AgentStatus(provider: provider, state: .notInstalled)
            return AsyncStream {
                $0.yield(.error(status.description))
                $0.finish()
            }
        })
}

/// Runs Ask AI (`AskAI`, WicketCore) for its frame: the question goes to the user's agent CLI in
/// answer mode (no tools), and the frame shows a detail that grows with the streamed text, at most
/// about 30 times a second, replaced by the final answer at the end. Its actions copy or paste the
/// answer. A provider that isn't ready, or a run that fails, ends the stream with an error the frame
/// shows; ending the iteration (pop, dismiss) kills the agent's process tree.
///
/// The provider is checked before each run, never at launch: the chosen one (`provider`, from
/// settings), else the first ready one in `AgentProvider.allCases` order. A provider found ready is
/// trusted for `statusLifetime`, so repeated questions skip the 20 to 150 ms check; one that isn't
/// ready is checked again every time, so signing in takes effect at once.
@MainActor
public final class AskAIRunner: CommandRunner {
    /// The settings' `ai.provider`; nil for the first ready one.
    public var provider: AgentProvider?
    private let backend: AgentBackend
    private let interval: Duration
    private let statusLifetime: Duration
    /// When each provider was last found ready.
    private var ready: [AgentProvider: ContinuousClock.Instant] = [:]
    private static let logger = Logger(subsystem: "app.wicket", category: "ai")

    /// `interval` is the shortest time between two shown updates while the answer streams.
    public init(
        backend: AgentBackend = .installed, interval: Duration = .milliseconds(33),
        statusLifetime: Duration = .seconds(60)
    ) {
        self.backend = backend
        self.interval = interval
        self.statusLifetime = statusLifetime
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let prompt = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = Task {
            do {
                guard !prompt.isEmpty else { throw Failure("There's no question to ask.") }
                try await answer(prompt, continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func answer(
        _ prompt: String, _ output: AsyncThrowingStream<RunResult, any Error>.Continuation
    ) async throws {
        let start = ContinuousClock.now
        let provider = try await readyProvider()
        try Task.checkCancellation()
        let draft = Draft(prompt: prompt, status: "Asking \(provider.name)…")
        output.yield(.detail(draft.detail))

        // An empty folder, so the agent's working directory holds nothing to read.
        let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-ask-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let throttle = Throttle(interval: interval) { output.yield(.detail(draft.detail)) }
        defer { throttle.cancel() }
        var firstText: Duration?
        let request = AgentRequest(prompt: prompt, workingDirectory: folder, mode: .answer)
        for await event in await backend.run(provider, request) {
            switch event {
            case .text(let delta):
                firstText = firstText ?? ContinuousClock.now - start
                draft.text += delta
                throttle.submit()
            case .activity(let activity):
                // A status until the answer starts; the answer is what matters after that.
                guard draft.text.isEmpty else { continue }
                draft.status = activity
                throttle.submit()
            case .answer(let answer, _):
                throttle.cancel()
                // The final message alone; anything streamed before it (commentary) goes.
                if !answer.isEmpty { draft.text = answer }
                guard !draft.text.isEmpty else { throw Failure("\(provider.name) sent an empty answer.") }
                output.yield(.detail(draft.detail))
                Self.logger.notice(
                    """
                    ask-ai: \(provider.rawValue, privacy: .public) first text after \
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

    /// The provider to ask, or an error saying why none can answer.
    private func readyProvider() async throws -> AgentProvider {
        let chosen = provider
        var statuses: [AgentStatus] = []
        for candidate in chosen.map({ [$0] }) ?? AgentProvider.allCases {
            if let checked = ready[candidate], ContinuousClock.now < checked + statusLifetime {
                return candidate
            }
            let start = ContinuousClock.now
            let status = await backend.status(candidate)
            Self.logger.notice(
                "ask-ai: \(candidate.rawValue, privacy: .public) status in \(ContinuousClock.now - start, privacy: .public)"
            )
            if status.state == .ready {
                ready[candidate] = .now
                return candidate
            }
            ready[candidate] = nil
            statuses.append(status)
        }
        throw Failure(Self.unavailable(statuses, chosen: chosen != nil))
    }

    /// What the frame says when no provider can answer.
    static func unavailable(_ statuses: [AgentStatus], chosen: Bool) -> String {
        let reasons = statuses.map(reason)
        if chosen, let reason = reasons.first {
            return reason + "\n\nYou can choose another provider in Settings ▸ AI."
        }
        let names = AgentProvider.allCases.map(\.name).joined(separator: " or ")
        return "Ask AI uses \(names), and neither is ready:\n\n"
            + reasons.map { "- \($0)" }.joined(separator: "\n")
    }

    static func reason(_ status: AgentStatus) -> String {
        let provider = status.provider
        return switch status.state {
        case .notInstalled: "\(provider.name) isn't installed: there's no `\(provider.command)` on your PATH."
        case .loggedOut:
            "\(provider.name) isn't signed in: run `\(provider.loginCommand)` in Terminal to sign in."
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
    let prompt: String
    /// Shown until the first text arrives.
    var status: String
    var text = ""

    init(prompt: String, status: String) {
        self.prompt = prompt
        self.status = status
    }

    /// The question is the title (the pill shows it), the answer the page.
    var detail: Detail {
        Detail(
            title: prompt, markdown: text.isEmpty ? "_\(status)_" : text,
            actions: [.copy(text: text, title: "Copy Answer"), .paste(text: text, title: "Paste Answer")])
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
