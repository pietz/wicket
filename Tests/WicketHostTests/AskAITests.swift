import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Ask AI end to end through a palette session: the runner behind the router, fed by a scripted agent
// backend (no processes), and once by a fake agent CLI replaying a recorded Codex stream.

/// Agents whose status the test sets and whose runs it drives through their continuations.
private final class FakeAgents: Sendable {
    struct Run {
        let provider: AgentProvider
        let request: AgentRequest
        let continuation: AsyncStream<AgentEvent>.Continuation
    }

    private struct State {
        var states: [AgentProvider: AgentStatus.State] = [:]
        var checks: [AgentProvider] = []
        var runs: [Run] = []
        var ended: Set<Int> = []
    }

    private let state = Mutex(State())

    init(_ states: [AgentProvider: AgentStatus.State]) {
        state.withLock { $0.states = states }
    }

    var backend: AgentBackend {
        AgentBackend(
            status: { provider in
                self.state.withLock {
                    $0.checks.append(provider)
                    return AgentStatus(provider: provider, state: $0.states[provider] ?? .notInstalled)
                }
            },
            run: { provider, request in
                let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
                self.state.withLock { state in
                    let index = state.runs.count
                    continuation.onTermination = { _ in self.state.withLock { _ = $0.ended.insert(index) } }
                    state.runs.append(Run(provider: provider, request: request, continuation: continuation))
                }
                return stream
            })
    }

    func set(_ provider: AgentProvider, _ status: AgentStatus.State) {
        state.withLock { $0.states[provider] = status }
    }

    var checks: [AgentProvider] { state.withLock { $0.checks } }
    var runs: [Run] { state.withLock { $0.runs } }
    func wasEnded(_ run: Int) -> Bool { state.withLock { $0.ended.contains(run) } }
}

@MainActor
private struct Palette {
    let session: PaletteSession
    let runner: AskAIRunner

    init(_ backend: AgentBackend, interval: Duration = .zero) {
        runner = AskAIRunner(backend: backend, interval: interval)
        let router = CommandRouter(builtins: [AskAI.command: runner], extensions: nil)
        let registry = CommandRegistry()
        session = PaletteSession(sources: [FallbackSource(registry)], runner: router, registry: registry)
    }

    /// Types `question` and picks the Ask AI row, as Return on it would.
    func ask(_ question: String) {
        session.query = question
        session.open(CommandRun(BuiltinCommand.askAI.registered, .invoked, text: question))
    }

    var detail: Detail? {
        if case .command(let frame) = session.top.content, case .detail(let detail) = frame.screen {
            detail
        } else {
            nil
        }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor @Test func theAnswerGrowsInPlaceAndTheFinalOneReplacesIt() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("capital of France?")
    // The frame opens with the question as its title and a status until the text comes.
    #expect(await eventually { palette.detail != nil })
    #expect(palette.detail?.title == "capital of France?")
    #expect(palette.detail?.markdown == "_Asking Codex…_")
    #expect(palette.session.top.isLoading)
    let frame = palette.session.top.id
    let run = try #require(agents.runs.first)
    #expect(run.provider == .codex)
    #expect(run.request.mode == .answer)
    #expect(run.request.prompt == "capital of France?")

    run.continuation.yield(.activity("Thinking"))
    #expect(await eventually { palette.detail?.markdown == "_Thinking_" })
    var text = ""
    for delta in ["**Paris**", " is the", " capital."] {
        text += delta
        run.continuation.yield(.text(delta))
        #expect(await eventually { palette.detail?.markdown == text })
        #expect(palette.session.top.id == frame)
        #expect(palette.session.top.target?.actions.first == .copy(text: text, title: "Copy Answer"))
    }
    // The final message alone replaces whatever streamed before it.
    run.continuation.yield(.answer("**Paris**.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "**Paris**.")
    #expect(
        palette.session.top.target?.actions == [
            .copy(text: "**Paris**.", title: "Copy Answer"),
            .paste(text: "**Paris**.", title: "Paste Answer"),
        ])
    #expect(palette.session.top.id == frame)
    #expect(palette.session.frames.count == 2)
}

@MainActor @Test func anAgentErrorBecomesTheFramesFailure() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.text("Hel"))
    agents.runs[0].continuation.yield(.error("the model is overloaded"))
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    #expect(palette.detail?.markdown == "the model is overloaded")
    #expect(!palette.session.top.isLoading)
}

@MainActor @Test func poppingOrDismissingStopsTheAgent() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("long story")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.text("Once upon"))
    #expect(await eventually { palette.detail?.markdown == "Once upon" })
    #expect(palette.session.escape() == .popped)
    #expect(await eventually { agents.wasEnded(0) })

    palette.ask("another")
    #expect(await eventually { agents.runs.count == 2 })
    palette.session.reset()
    #expect(await eventually { agents.wasEnded(1) })
    #expect(palette.session.frames.count == 1)
}

@MainActor @Test func aProviderThatIsNotReadySaysWhatToDo() async throws {
    // Automatic: the first ready one, Codex first.
    let agents = FakeAgents([.codex: .notInstalled, .claude: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hi")
    #expect(await eventually { agents.runs.count == 1 })
    #expect(agents.runs[0].provider == .claude)
    #expect(agents.checks == [.codex, .claude])

    // Chosen in settings: that one or nothing, never another.
    agents.set(.codex, .loggedOut)
    palette.runner.provider = .codex
    palette.ask("hi")
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    #expect(
        palette.detail?.markdown
            == "Codex isn't signed in: run `codex login` in Terminal to sign in.\n\n"
            + "You can choose another provider in Settings ▸ AI.")
    #expect(agents.runs.count == 1)

    // Neither ready (a new runner: this one found Claude ready a moment ago, and trusts that).
    agents.set(.claude, .loggedOut)
    let fresh = Palette(agents.backend)
    fresh.ask("hi")
    #expect(await eventually { fresh.detail?.title == "Ask AI Failed" })
    #expect(
        fresh.detail?.markdown == """
            Ask AI uses Codex or Claude Code, and neither is ready:

            - Codex isn't signed in: run `codex login` in Terminal to sign in.
            - Claude Code isn't signed in: run `claude auth login` in Terminal to sign in.
            """)
}

@MainActor @Test func aReadyProviderIsTrustedForAWhile() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    for count in 1...3 {
        palette.ask("q\(count)")
        #expect(await eventually { agents.runs.count == count })
        agents.runs[count - 1].continuation.yield(.answer("a", usage: nil))
        #expect(await eventually { !palette.session.top.isLoading })
        palette.session.reset()
    }
    #expect(agents.checks == [.codex])

    // A failed run checks again next time.
    palette.ask("q4")
    #expect(await eventually { agents.runs.count == 4 })
    agents.runs[3].continuation.yield(.error("logged out"))
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    palette.session.reset()
    palette.ask("q5")
    #expect(await eventually { agents.runs.count == 5 })
    #expect(agents.checks == [.codex, .codex])
}

@MainActor @Test func frequentDeltasAreCoalesced() async throws {
    let agents = FakeAgents([.codex: .ready])
    let runner = AskAIRunner(backend: agents.backend, interval: .seconds(60))
    let stream = runner.run(
        Invocation(command: AskAI.command, text: "count"), retry: .never)
    let events: [AgentEvent] = [.text("1"), .text(" 2"), .text(" 3"), .answer("1 2 3", usage: nil)]
    let feed = Task {
        while agents.runs.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        for event in events { agents.runs[0].continuation.yield(event) }
    }
    var shown: [String] = []
    for try await result in stream {
        if case .detail(let detail) = result { shown.append(detail.markdown) }
    }
    try await feed.value
    // The status, the first text at once, then nothing until the interval is up: the answer ended it.
    #expect(shown == ["_Asking Codex…_", "1", "1 2 3"])
}

@MainActor @Test func aRecordedCodexAnswerThroughTheRealAdapter() async throws {
    let agent = try replaying(.codex, "codex-answer")
    let backend = AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) }, run: { _, request in agent.run(request) })
    let palette = Palette(backend)
    palette.ask("What is the capital of France?")
    #expect(await eventually { palette.detail?.markdown == "Paris" && !palette.session.top.isLoading })
    #expect(palette.detail?.title == "What is the capital of France?")
}
