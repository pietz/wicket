import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Run Agent end to end through a palette session: the runner behind the router, fed by a scripted agent
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

/// Run Agent as the app's table registers it (`AppRuntime.live()`).
private let runAgent = RegisteredCommand(
    id: .builtin("run-agent"), title: "Run Agent", icon: .symbol(name: "sparkles"), keyword: "ai",
    isListed: false,
    input: .submitText, placeholder: "Ask a question", isFallback: true, feature: .ai)
private let followUp = RegisteredCommand(
    id: .followUp, title: "Follow Up", icon: .symbol(name: "sparkles"), isListed: false, input: .submitText,
    placeholder: "Follow up", feature: .ai)
private let aiApproval = RegisteredCommand(
    id: .aiApproval, title: "Answer the Agent", icon: .symbol(name: "sparkles"), isListed: false, input: .none
)

@MainActor
private struct Palette {
    let session: PaletteSession
    let runner: AgentRunner

    /// Streaming by default, which most tests here watch; `ai.streamAnswers` is off in the app.
    init(_ backend: AgentBackend, interval: Duration = .zero, streams: Bool = true) {
        let answers = AnswerStream(backend: backend, interval: interval)
        answers.streamsAnswers = { streams }
        runner = AgentRunner(answers: answers)
        let router = CommandRouter(
            builtins: [
                Builtin(runAgent, runner: runner), Builtin(followUp, runner: runner),
                Builtin(aiApproval, runner: runner),
            ],
            extensions: nil)
        let registry = CommandRegistry(builtins: [runAgent, followUp, aiApproval])
        session = PaletteSession(sources: [FallbackSource(registry)], runner: router, registry: registry)
    }

    /// Types `question` and picks the Run Agent row, as Return on it would.
    func ask(_ question: String) {
        session.query = question
        session.open(CommandRun(runAgent, .invoked, text: question))
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
    #expect(palette.detail?.markdown == "_Asking ChatGPT…_")
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
    #expect(run.request.configuration != nil)
    #expect(run.request.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
    #expect(run.request.prompt == "capital of France?")

    // Tool use isn't shown.
    run.continuation.yield(.activity("Ran ls *.md"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(palette.detail?.markdown == "_Asking ChatGPT…_")
    var text = ""
    for delta in ["**Paris**", " is the", " capital."] {
        text += delta
        run.continuation.yield(.text(delta))
        #expect(await eventually { palette.detail?.markdown == text })
        #expect(palette.session.top.id == frame)
        #expect(palette.session.top.target?.actions.first == .copy(text: text, title: "Copy Answer"))
    }
    // A final answer that isn't what streamed replaces it, so the page ends exactly on the answer.
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
    let retry = Item.Action.run(command: runAgent.id, text: "hello", title: "Retry")
    #expect(palette.session.top.target?.actions == [retry, .copy(text: "Hel", title: "Copy Answer")])
    #expect(agents.runs.count == 1)
    #expect(agents.wasEnded(0))

    palette.session.open(CommandRun(runAgent, .invoked, text: "hello"))
    #expect(await eventually { agents.runs.count == 2 })
    #expect(agents.runs[1].request.prompt == "hello")
}

@MainActor @Test func anErrorBeforeAnyTextOffersRetry() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.error("the model is overloaded"))
    #expect(await eventually { palette.detail?.title == "Run Agent Failed" })
    #expect(palette.detail?.markdown == "the model is overloaded")
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(
        palette.session.top.target?.actions == [.run(command: runAgent.id, text: "hello", title: "Retry")])
}

@MainActor @Test func poppingOrDismissingStopsTheAgent() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("long story")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.text("Once upon"))
    #expect(await eventually { palette.detail?.markdown == "Once upon" })
    #expect(palette.session.back())
    #expect(await eventually { agents.wasEnded(0) })

    palette.ask("another")
    #expect(await eventually { agents.runs.count == 2 })
    palette.session.reset()
    #expect(await eventually { agents.wasEnded(1) })
    #expect(palette.session.frames.count == 1)
}

@MainActor @Test func aProviderThatIsNotReadySaysWhatToDo() async throws {
    // None chosen: the first ready one, Claude first.
    let agents = FakeAgents([.claude: .notInstalled, .codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hi")
    #expect(await eventually { agents.runs.count == 1 })
    #expect(agents.runs[0].provider == .codex)
    #expect(agents.checks == [.claude, .codex])

    // Chosen in settings: that one or nothing, never another.
    agents.set(.claude, .ready)
    agents.set(.codex, .loggedOut)
    palette.runner.answers.provider = { .codex }
    palette.ask("hi")
    #expect(await eventually { palette.detail?.title == "Run Agent Failed" })
    #expect(
        palette.detail?.markdown
            == "Codex isn't signed in: run `codex login` in Terminal to sign in.\n\n"
            + "You can choose another provider in Settings ▸ AI.")
    #expect(
        palette.session.top.target?.actions == [.run(command: .aiSettings, title: "Open AI Settings")])
    #expect(agents.runs.count == 1)

    // None ready.
    agents.set(.claude, .loggedOut)
    let fresh = Palette(agents.backend)
    fresh.ask("hi")
    #expect(await eventually { fresh.detail?.title == "Run Agent Failed" })
    #expect(
        fresh.detail?.markdown == """
            Run Agent uses Claude or ChatGPT, and none is ready:

            - Claude Code isn't signed in: run `claude auth login` in Terminal to sign in.
            - Codex isn't signed in: run `codex login` in Terminal to sign in.
            """)
}

/// Status is checked before every run, never cached: a provider that signs out is reported on the
/// next question, and one that signs in again answers the one after.
@MainActor @Test func readinessIsCheckedBeforeEveryRun() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.runner.answers.provider = { .codex }
    palette.ask("q1")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.answer("a", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    palette.session.reset()

    agents.set(.codex, .loggedOut)
    palette.ask("q2")
    #expect(await eventually { palette.detail?.title == "Run Agent Failed" })
    #expect(agents.runs.count == 1)
    palette.session.reset()

    agents.set(.codex, .ready)
    palette.ask("q3")
    #expect(await eventually { agents.runs.count == 2 })
    #expect(agents.checks == [.codex, .codex, .codex])
}

@MainActor @Test func frequentDeltasAreCoalesced() async throws {
    let agents = FakeAgents([.codex: .ready])
    let answers = AnswerStream(backend: agents.backend, interval: .seconds(60))
    answers.streamsAnswers = { true }
    let runner = AgentRunner(answers: answers)
    let stream = runner.run(
        Invocation(command: runAgent.id, text: "count"), retry: .never)
    let events: [AgentEvent] = [.text("1"), .text(" 2"), .text(" 3"), .answer("1 2 3", usage: nil)]
    let feed = Task {
        while agents.runs.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        for event in events { agents.runs[0].continuation.yield(event) }
    }
    var shown: [String] = []
    for try await result in stream {
        if case .show(.detail(let detail), _) = result { shown.append(detail.markdown) }
    }
    try await feed.value
    // The status, the first text at once, then nothing until the interval is up: the answer ended it.
    #expect(shown == ["_Asking ChatGPT…_", "1", "1 2 3"])
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

@MainActor @Test func aChosenProviderIsRecheckedAndNeverFallsBack() async throws {
    let agents = FakeAgents([.codex: .ready, .claude: .ready])
    let palette = Palette(agents.backend)
    palette.runner.answers.provider = { .claude }
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.answer("Hello!", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    palette.session.reset()

    agents.set(.claude, .loggedOut)
    palette.ask("hello again")
    #expect(await eventually { palette.detail?.title == "Run Agent Failed" })
    #expect(palette.detail?.markdown.contains("claude auth login") == true)
    #expect(palette.detail?.actions == [.run(command: .aiSettings, title: "Open AI Settings")])
    #expect(agents.checks == [.claude, .claude])
    #expect(agents.runs.count == 1)
}

@MainActor @Test func whatWasSelectedFollowsTheQuestionAndTheTitleStaysTheQuestion() async throws {
    let agents = FakeAgents([.codex: .ready])
    let runner = AgentRunner(answers: AnswerStream(backend: agents.backend, interval: .zero))
    let context = try #require(SummonContext(app: "Mail", text: "Dear Anna, thanks again."))
    var shown: [RunResult] = []
    let stream = runner.run(
        Invocation(command: runAgent.id, text: "translate this to German", context: context), retry: .never)
    let reading = Task {
        for try await result in stream { shown.append(result) }
    }
    defer { reading.cancel() }
    #expect(await eventually { !agents.runs.isEmpty })
    let prompt = try #require(agents.runs.first).request.prompt
    #expect(prompt == "translate this to German\n\n" + context.promptBlock)
    var title: String? {
        guard case .show(.detail(let detail), _) = shown.last else { return nil }
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
    let command = AgentApproval(
        id: .integer(0), kind: .command, subject: "echo hi > hello.txt", reason: "Create it?",
        workingDirectory: "/tmp/work")
    let files = AgentApproval(
        id: .string("r2"), kind: .fileChange, subject: "add notes.md", grantRoot: "/tmp/work")
    run.continuation.yield(.approvals([command, files]))
    #expect(await eventually { palette.detail?.actions.count == 3 })
    #expect(palette.detail?.actions.map(\.title) == ["Allow", "Allow for Session", "Deny"])
    // Captured once the answer's frame is up: it is pushed with the first content, not with the run.
    let frame = palette.session.top.id
    #expect(
        palette.detail?.markdown
            == "**The agent asks to run a command** in /tmp/work.\n\nCreate it?\n\n```\necho hi > hello.txt\n```\n\n_Auto: approves routine actions, asks about the rest._\n\n_1 more waiting_\n\n_Asking ChatGPT…_"
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
            palette.detail?.markdown.hasPrefix(
                "**The agent asks to change files:** add notes\\.md\n\nIt asks to write anywhere in /tmp/work for the rest of this run."
            ) == true
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

@MainActor @Test func closingWhileAnApprovalWaitsStopsTheAgentAndTheActionExpires() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("delete the logs")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(
        .approvals([AgentApproval(id: .integer(0), kind: .command, subject: "rm *.log")]))
    #expect(await eventually { palette.detail?.actions.first?.title == "Allow" })
    let allow = try #require(palette.detail?.actions.first)
    palette.session.reset()  // The palette closes.
    #expect(await eventually { agents.wasEnded(0) })
    await palette.runner.shutdown()  // Returns once the run has ended and cleaned up.

    // An expired token changes nothing: the frame beneath stays as it is, never covered by a failure.
    guard case .run(_, _, let args, _, _) = allow else { return }
    var results: [RunResult] = []
    for try await result in palette.runner.run(Invocation(command: .aiApproval, args: args), retry: .never) {
        results.append(result)
    }
    #expect(results == [.stay])
}

@MainActor @Test func agentCLIsWorkInTheFinderSelectionsFolderAndAppleOnlyAnswers() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/sel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "a.txt")
    try Data().write(to: file)
    #expect(
        AgentRunner.folder(for: SummonContext(app: "Finder", files: [file]))
            == file.deletingLastPathComponent())
    #expect(AgentRunner.folder(for: SummonContext(app: "Finder", files: [folder])) == folder)
    #expect(
        AgentRunner.folder(for: SummonContext(app: "Mail", text: "hi"))
            == FileManager.default.homeDirectoryForCurrentUser)

    let agents = FakeAgents([.codex: .loggedOut, .claude: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    #expect(agents.runs[0].provider == .claude)
    #expect(agents.runs[0].request.configuration != nil)
    #expect(agents.runs[0].request.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
}

@MainActor @Test func messagesAlongTheWayStayAboveTheFinalAnswer() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("search the web for it")
    #expect(await eventually { agents.runs.count == 1 })
    let run = try #require(agents.runs.first)
    run.continuation.yield(.text("Let me search for that."))
    run.continuation.yield(.activity("Searched the web"))
    run.continuation.yield(.text("\n\nIt is 42."))
    run.continuation.yield(.answer("It is 42.", usage: nil))
    #expect(await eventually { palette.detail?.actions.isEmpty == false && !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "Let me search for that.\n\nIt is 42.")
    // Copy and Paste take the final answer alone.
    #expect(palette.detail?.actions.first == .copy(text: "It is 42.", title: "Copy Answer"))
}

@MainActor @Test func followUpContinuesTheAgentsSessionWithTheConversationsSetup() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("make a notes folder")
    #expect(await eventually { agents.runs.count == 1 })
    let first = try #require(agents.runs.first)
    first.continuation.yield(.session("t1"))
    first.continuation.yield(.answer("Made it.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading && palette.detail?.actions.isEmpty == false })
    // Second, so ⌘↩ runs it.
    let actions = try #require(palette.detail?.actions)
    #expect(actions.map(\.title) == ["Copy Answer", "Follow Up", "Paste Answer"])
    guard case .run(let command, let text, let args, _, _) = actions[1] else {
        Issue.record("Follow Up is not a run")
        return
    }
    #expect(command == .followUp && text.isEmpty)

    // It opens the input waiting for the question, as the pill; Escape there goes back to the answer.
    let answer = palette.session.top.id
    palette.session.open(CommandRun(followUp, .invoked, args: args))
    #expect(palette.session.top.awaitsText && palette.session.top.isCompact)
    #expect(palette.session.back())
    #expect(palette.session.top.id == answer)

    // Submitted, the question continues the conversation: its session, provider, folder and settings,
    // even with another provider ready now.
    agents.set(.claude, .ready)
    palette.session.open(CommandRun(followUp, .invoked, args: args))
    palette.session.query = "now add a readme"
    guard case .run(_, let question, let submitted, _, _)? = palette.session.top.target?.actions.first else {
        Issue.record("the follow-up input submits nothing")
        return
    }
    palette.session.open(CommandRun(followUp, .invoked, text: question, args: submitted))
    #expect(await eventually { agents.runs.count == 2 })
    let second = agents.runs[1]
    #expect(second.provider == first.provider)
    #expect(second.request.prompt == "now add a readme")
    #expect(second.request.resume == "t1")
    #expect(second.request.workingDirectory == first.request.workingDirectory)
    #expect(second.request.configuration == first.request.configuration)
    #expect(await eventually { palette.detail?.title == "now add a readme" })
    // Its answer continues the same conversation again.
    second.continuation.yield(.session("t1"))
    second.continuation.yield(.answer("Added README.md.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading && palette.detail?.actions.isEmpty == false })
    #expect(palette.detail?.actions[1] == actions[1])
}

@MainActor @Test func noFollowUpWithoutASessionAndAnUnknownConversationSaysItEnded() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.answer("Hi.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading && palette.detail?.actions.isEmpty == false })
    #expect(palette.detail?.actions.map(\.title) == ["Copy Answer", "Paste Answer"])

    palette.session.open(
        CommandRun(followUp, .invoked, text: "and?", args: ["conversation": .string("gone")]))
    #expect(await eventually { palette.detail?.title == "Follow Up Failed" })
    #expect(agents.runs.count == 1)
}

/// `ai.streamAnswers` off (the default): the page says the agent is working, shows each message once
/// it is whole, still shows an approval at once, and the answer all at once.
@MainActor @Test func withoutStreamingMessagesShowWholeAndApprovalsAtOnce() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend, streams: false)
    palette.ask("search the web for it")
    #expect(await eventually { agents.runs.count == 1 })
    let run = try #require(agents.runs.first)
    #expect(await eventually { palette.detail?.markdown == "_Asking ChatGPT…_" })
    run.continuation.yield(.text("Let me search"))
    run.continuation.yield(.text(" for that."))
    // Nothing to wait for: deltas must not show, so give them time to (wrongly) arrive.
    try await Task.sleep(for: .milliseconds(50))
    #expect(palette.detail?.markdown == "_Asking ChatGPT…_")
    #expect(palette.session.top.target == nil)
    run.continuation.yield(.messageEnd)
    #expect(await eventually { palette.detail?.markdown == "Let me search for that." })

    let approval = AgentApproval(id: .integer(0), kind: .network, subject: "example.com")
    run.continuation.yield(.approvals([approval]))
    #expect(await eventually { palette.detail?.actions.first?.title == "Allow" })
    #expect(palette.detail?.markdown.hasSuffix("\n\nLet me search for that.") == true)
    run.continuation.yield(.approvals([]))
    // Sync on the approval leaving before checking that a delta doesn't show.
    #expect(await eventually { palette.detail?.actions.first?.title != "Allow" })
    run.continuation.yield(.text("\n\nIt is"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(palette.detail?.markdown == "Let me search for that.")
    // The answer can come without its message's end; it shows whole either way.
    run.continuation.yield(.text(" 42."))
    run.continuation.yield(.answer("It is 42.", usage: nil))
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "Let me search for that.\n\nIt is 42.")
    #expect(palette.detail?.actions.first == .copy(text: "It is 42.", title: "Copy Answer"))
}

@MainActor @Test func withoutStreamingAFailureStillKeepsWhatWasWritten() async throws {
    let agents = FakeAgents([.codex: .ready])
    let palette = Palette(agents.backend, streams: false)
    palette.ask("hello")
    #expect(await eventually { agents.runs.count == 1 })
    agents.runs[0].continuation.yield(.text("Hel"))
    agents.runs[0].continuation.yield(.error("the model is overloaded"))
    #expect(await eventually { !palette.session.top.isLoading })
    #expect(palette.detail?.markdown == "Hel\n\n---\n\n**The answer is incomplete.** the model is overloaded")
}
