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
        let replies: AsyncStream<AgentReply>
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
                AgentRun { continuation, replies in
                    let index = self.state.withLock { state in
                        state.runs.append(
                            Run(
                                provider: provider, request: request, continuation: continuation,
                                replies: replies))
                        return state.runs.count - 1
                    }
                    // Runs until the runner ends it, which it always does (after the last event too).
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                    self.state.withLock { _ = $0.ended.insert(index) }
                    return .exited(.status(0))
                }
            })
    }

    func set(_ provider: AgentProvider, _ status: AgentStatus.State) {
        state.withLock { $0.states[provider] = status }
    }

    var checks: [AgentProvider] { state.withLock { $0.checks } }
    var runs: [Run] { state.withLock { $0.runs } }
    func wasEnded(_ run: Int) -> Bool { state.withLock { $0.ended.contains(run) } }
}

/// Ask AI as the app's table registers it (`AppRuntime.live()`).
private let askAI = RegisteredCommand(
    id: .builtin("ask-ai"), title: "Ask AI", icon: .symbol(name: "sparkles"), keyword: "ai", isListed: false,
    input: .submitText, placeholder: "Ask a question", isFallback: true, feature: .askAI)
private let aiApproval = RegisteredCommand(
    id: .aiApproval, title: "Answer the Agent", icon: .symbol(name: "sparkles"), isListed: false, input: .none
)

@MainActor
private struct Palette {
    let session: PaletteSession
    let runner: AskAIRunner

    init(_ backend: AgentBackend, interval: Duration = .zero) {
        runner = AskAIRunner(backend: backend, interval: interval)
        let router = CommandRouter(
            builtins: [Builtin(askAI, runner: runner), Builtin(aiApproval, runner: runner)], extensions: nil)
        let registry = CommandRegistry(builtins: [askAI, aiApproval])
        session = PaletteSession(sources: [FallbackSource(registry)], runner: router, registry: registry)
    }

    /// Types `question` and picks the Ask AI row, as Return on it would.
    func ask(_ question: String) {
        session.query = question
        session.open(CommandRun(askAI, .invoked, text: question))
    }

    /// Picks one of the top frame's actions by title, as the action menu would: a `run` opens its
    /// command, the rest are ignored here.
    func pick(_ title: String) throws {
        let action = try #require(session.top.target?.actions.first { $0.title == title })
        guard case .run(let command, let text, let args, _, _) = action else { return }
        #expect(command == aiApproval.id)
        session.open(
            CommandRun(
                command: aiApproval, invocation: Invocation(command: command, text: text, args: args),
                retry: .never))
    }

    var detail: Detail? {
        if case .screen(let frame) = session.top.content, case .detail(let detail) = frame.screen {
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
    // Nothing to copy or paste yet: Return does nothing rather than clear the clipboard.
    #expect(palette.detail?.actions == [])
    #expect(palette.session.top.target == nil)
    let frame = palette.session.top.id
    // The status shows before the agent is asked.
    #expect(await eventually { !agents.runs.isEmpty })
    let run = try #require(agents.runs.first)
    #expect(run.provider == .codex)
    // Codex acts, in the home folder when nothing was selected in Finder.
    #expect(run.request.mode == .act)
    #expect(run.request.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
    #expect(run.request.prompt == "capital of France?")

    // What the agent does shows as progress above the answer, escaped.
    run.continuation.yield(.activity("Ran ls *.md"))
    #expect(await eventually { palette.detail?.markdown == "- Ran ls \\*\\.md\n\n_Asking Codex…_" })
    var text = ""
    for delta in ["**Paris**", " is the", " capital."] {
        text += delta
        run.continuation.yield(.text(delta))
        #expect(await eventually { palette.detail?.markdown == "- Ran ls \\*\\.md\n\n" + text })
        #expect(palette.session.top.id == frame)
        #expect(palette.session.top.target?.actions.first == .copy(text: text, title: "Copy Answer"))
    }
    // The final message alone replaces whatever streamed before it.
    run.continuation.yield(.answer("**Paris**.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "- Ran ls \\*\\.md\n\n**Paris**.")
    #expect(
        palette.session.top.target?.actions == [
            .copy(text: "**Paris**.", title: "Copy Answer"),
            .paste(text: "**Paris**.", title: "Paste Answer"),
        ])
    #expect(palette.session.top.id == frame)
    #expect(palette.session.frames.count == 2)
}

@MainActor @Test func aLateErrorKeepsThePartialAnswer() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.text("Hel"))
    agents.runs[0].continuation.yield(.error("the model is overloaded"))
    #expect(await eventually { palette.detail?.markdown.contains("incomplete") == true })
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.title == "hello")
    #expect(palette.detail?.markdown == "Hel\n\n---\n\n**The answer is incomplete.** the model is overloaded")
    // Retry asks the same question again, only when picked; Copy takes the text without the note.
    let retry = Item.Action.run(command: askAI.id, text: "hello", title: "Retry")
    #expect(palette.session.top.target?.actions == [retry, .copy(text: "Hel", title: "Copy Answer")])
    #expect(agents.runs.count == 1)
    #expect(agents.wasEnded(0))

    palette.session.open(CommandRun(askAI, .invoked, text: "hello"))
    #expect(await eventually { agents.runs.count == 2 })
    #expect(agents.runs[1].request.prompt == "hello")
}

@MainActor @Test func anErrorBeforeAnyTextOffersRetry() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.error("the model is overloaded"))
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    #expect(palette.detail?.markdown == "the model is overloaded")
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(
        palette.session.top.target?.actions == [.run(command: askAI.id, text: "hello", title: "Retry")])
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
    palette.runner.provider = { .codex }
    palette.ask("hi")
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    #expect(
        palette.detail?.markdown
            == "Codex isn't signed in: run `codex login` in Terminal to sign in.\n\n"
            + "You can choose another provider in Settings ▸ AI.")
    #expect(
        palette.session.top.target?.actions == [.run(command: .aiSettings, title: "Open AI Settings")])
    #expect(agents.runs.count == 1)

    // None ready (a new runner: this one found Claude ready a moment ago, and trusts that).
    agents.set(.claude, .loggedOut)
    agents.set(.apple, .unavailable("The on-device model is not ready."))
    let fresh = Palette(agents.backend)
    fresh.ask("hi")
    #expect(await eventually { fresh.detail?.title == "Ask AI Failed" })
    #expect(
        fresh.detail?.markdown == """
            Ask AI uses Codex or Claude Code or Apple Intelligence (on device), and none is ready:

            - Codex isn't signed in: run `codex login` in Terminal to sign in.
            - Claude Code isn't signed in: run `claude auth login` in Terminal to sign in.
            - Apple Intelligence (on device) is unavailable: The on-device model is not ready.
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
        Invocation(command: askAI.id, text: "count"), retry: .never)
    let events: [AgentEvent] = [.text("1"), .text(" 2"), .text(" 3"), .answer("1 2 3", usage: nil)]
    let feed = Task {
        while agents.runs.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        for event in events { agents.runs[0].continuation.yield(event) }
    }
    var shown: [String] = []
    for try await result in stream {
        if case .show(.detail(let detail)) = result { shown.append(detail.markdown) }
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

@MainActor @Test func appleAnswersUseTheExistingStreamingDraft() async throws {
    let agents = FakeAgents([.codex: .loggedOut, .claude: .loggedOut, .apple: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    let run = try #require(agents.runs.first)
    #expect(run.provider == .apple)
    #expect(run.request.mode == .answer)
    #expect(agents.checks == [.codex, .claude, .apple])
    run.continuation.yield(.text("Hello"))
    #expect(await eventually { palette.detail?.markdown == "Hello" })
    run.continuation.yield(.answer("Hello!", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "Hello!")
    #expect(
        palette.detail?.actions == [
            .copy(text: "Hello!", title: "Copy Answer"),
            .paste(text: "Hello!", title: "Paste Answer"),
        ])
}

@MainActor @Test func appleAvailabilityIsRecheckedAndNeverFallsBack() async throws {
    let agents = FakeAgents([.codex: .ready, .apple: .ready])
    let palette = Palette(agents.backend)
    palette.runner.provider = { .apple }
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.answer("Hello!", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    palette.session.reset()

    let reason = "Enable Apple Intelligence in System Settings ▸ Apple Intelligence & Siri."
    agents.set(.apple, .unavailable(reason))
    palette.ask("hello again")
    #expect(await eventually { palette.detail?.title == "Ask AI Failed" })
    #expect(palette.detail?.markdown.contains(reason) == true)
    #expect(palette.detail?.actions == [.run(command: .aiSettings, title: "Open AI Settings")])
    #expect(agents.checks == [.apple, .apple])
    #expect(agents.runs.count == 1)
}

@MainActor @Test func whatWasSelectedFollowsTheQuestionAndTheTitleStaysTheQuestion() async throws {
    let agents = FakeAgents([.codex: .ready])
    let runner = AskAIRunner(backend: agents.backend, interval: .zero)
    let context = try #require(SummonContext(app: "Mail", text: "Dear Anna, thanks again."))
    var shown: [RunResult] = []
    let stream = runner.run(
        Invocation(command: askAI.id, text: "translate this to German", context: context), retry: .never)
    let reading = Task {
        for try await result in stream { shown.append(result) }
    }
    defer { reading.cancel() }
    #expect(await eventually { !agents.runs.isEmpty })
    let prompt = try #require(agents.runs.first).request.prompt
    #expect(prompt == "translate this to German\n\n" + context.promptBlock)
    var title: String? {
        guard case .show(.detail(let detail)) = shown.last else { return nil }
        return detail.title
    }
    #expect(await eventually { title == "translate this to German" })
}

@MainActor @Test func approvalsAreAnsweredInTheAnswerAndTheFrameStays() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("make hello.txt")
    #expect(await eventually { agents.runs.count == 1 })
    let run = agents.runs[0]
    let frame = palette.session.top.id
    let command = AgentApproval(
        id: .integer(0), kind: .command, subject: "echo hi > hello.txt", reason: "Create it?")
    let files = AgentApproval(id: .string("r2"), kind: .fileChange, subject: "add notes.md")
    run.continuation.yield(.approvals([command, files]))
    #expect(await eventually { palette.detail?.actions.count == 3 })
    #expect(palette.detail?.actions.map(\.title) == ["Allow", "Allow for Session", "Deny"])
    #expect(
        palette.detail?.markdown
            == "**The agent asks to run a command.**\n\nCreate it?\n\n```\necho hi > hello.txt\n```\n\n_1 more waiting_\n\n_Asking Codex…_"
    )

    // Allow goes to the agent; its frame goes and the answer's frame keeps running.
    var replies = run.replies.makeAsyncIterator()
    try palette.pick("Allow")
    #expect(await replies.next() == AgentReply(approval: command, decision: .accept))
    #expect(await eventually { palette.session.opening == nil })
    #expect(palette.session.top.id == frame)
    #expect(palette.session.frames.count == 2)
    // The next one shows at once, even before the agent confirms the first resolved.
    #expect(
        await eventually {
            palette.detail?.markdown.hasPrefix("**The agent asks to change files:** add notes\\.md") == true
        })
    run.continuation.yield(.approvals([command, files]))
    try await Task.sleep(for: .milliseconds(20))
    #expect(palette.detail?.markdown.hasPrefix("**The agent asks to change files:**") == true)

    try palette.pick("Deny")
    #expect(await replies.next() == AgentReply(approval: files, decision: .decline))
    #expect(await eventually { palette.detail?.actions.isEmpty == true })
    run.continuation.yield(.approvals([]))
    run.continuation.yield(.answer("Created hello.txt.", usage: nil))
    #expect(await eventually { palette.detail?.markdown == "Created hello.txt." })
    #expect(palette.detail?.actions.first == .copy(text: "Created hello.txt.", title: "Copy Answer"))
}

@MainActor @Test func escapeWhileAnApprovalWaitsStopsTheAgentAndTheActionExpires() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("delete the logs")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(
        .approvals([AgentApproval(id: .integer(0), kind: .command, subject: "rm *.log")]))
    #expect(await eventually { palette.detail?.actions.first?.title == "Allow" })
    let allow = try #require(palette.detail?.actions.first)
    #expect(palette.session.escape() == .popped)
    #expect(await eventually { agents.wasEnded(0) })
    await palette.runner.shutdown()  // Returns once the run has ended and cleaned up.

    guard case .run(_, _, let args, _, _) = allow else { return }
    var thrown: (any Error)?
    do {
        for try await _ in palette.runner.run(Invocation(command: .aiApproval, args: args), retry: .never) {}
    } catch { thrown = error }
    #expect(
        String(describing: thrown ?? CancellationError())
            == "This question was already answered or has ended.")
}

@MainActor @Test func codexWorksInTheFinderSelectionsFolderAndOtherProvidersOnlyAnswer() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/sel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "a.txt")
    try Data().write(to: file)
    #expect(
        AskAIRunner.folder(for: SummonContext(app: "Finder", files: [file]))
            == file.deletingLastPathComponent())
    #expect(AskAIRunner.folder(for: SummonContext(app: "Finder", files: [folder])) == folder)
    #expect(
        AskAIRunner.folder(for: SummonContext(app: "Mail", text: "hi"))
            == FileManager.default.homeDirectoryForCurrentUser)

    let agents = FakeAgents([.codex: .loggedOut, .claude: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    #expect(agents.runs[0].provider == .claude)
    #expect(agents.runs[0].request.mode == .answer)
    #expect(agents.runs[0].request.workingDirectory.lastPathComponent.hasPrefix("wicket-ask-"))
}
