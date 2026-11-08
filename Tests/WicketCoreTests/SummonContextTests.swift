import Foundation
import Testing

@testable import WicketCore

// The Finder selection at summon: the value, and how the session hands it to the commands that use
// it (Run Agent) and to no other.

@Test func nothingSelectedIsNoContext() {
    #expect(SummonContext(files: []) == nil)
}

@Test func theSummarySaysHowMany() throws {
    let files = ["a.pdf", "b.png", "c"].map { URL(filePath: "/tmp/\($0)") }
    #expect(try #require(SummonContext(files: files)).summary == "Finder · 3 items")
    #expect(try #require(SummonContext(files: [files[0]])).summary == "Finder · 1 item")
}

@Test func thePromptBlockIsTaggedAndHoldsTheFiles() throws {
    let files = try #require(SummonContext(files: [URL(filePath: "/Users/me/a b.pdf")]))
    #expect(
        files.promptBlock == """
            <context>
            The user asked this from Finder, with these selected:
            <selected_files>
            /Users/me/a b.pdf
            </selected_files>
            </context>
            """)
}

/// Records each run and never answers.
@MainActor
private final class RecordingRunner: CommandRunner {
    var runs: [Invocation] = []

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        return AsyncThrowingStream { _ in }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private let mail = SummonContext(files: [URL(filePath: "/Users/me/Letters/anna.txt")])!
private let echo = RegisteredCommand(id: .extension("echo", "say"), title: "Say", icon: .symbol(name: "text"))

@MainActor
private func session(wait: Duration = .seconds(5)) -> (PaletteSession, RecordingRunner) {
    let runner = RecordingRunner()
    let session = PaletteSession(
        sources: [], runner: runner, registry: CommandRegistry(builtins: builtins + [echo]),
        contextWait: wait)
    return (session, runner)
}

@MainActor @Test func onlyACommandThatUsesTheContextGetsIt() async throws {
    let (session, runner) = session()
    session.captureContext(Task { mail })
    #expect(await eventually { session.context == mail })

    session.open(CommandRun(.runAgent, .invoked, text: "translate this to German"))
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.runs[0].context == mail)
    #expect(runner.runs[0].text == "translate this to German")

    session.open(CommandRun(echo, .invoked, text: "hi"))
    #expect(await eventually { runner.runs.count == 2 })
    #expect(runner.runs[1].context == nil)
}

@MainActor @Test func aRunWaitsForACaptureStillRunning() async throws {
    let (session, runner) = session()
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    session.captureContext(
        Task {
            for await _ in gate { break }
            return mail
        })
    session.open(CommandRun(.runAgent, .invoked, text: "what is this?"))
    try await Task.sleep(for: .milliseconds(50))
    // Nothing is shown and nothing runs until the capture is done.
    #expect(session.context == nil)
    #expect(runner.runs.isEmpty)
    open.yield()
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.runs[0].context == mail)
    #expect(session.context == mail)
}

@MainActor @Test func aSlowCaptureIsNotWaitedForPastTheLimit() async throws {
    let (session, runner) = session(wait: .milliseconds(30))
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    defer { open.finish() }
    session.captureContext(
        Task {
            for await _ in gate { break }
            return mail
        })
    let start = ContinuousClock.now
    session.open(CommandRun(.runAgent, .invoked, text: "what is this?"))
    #expect(await eventually { runner.runs.count == 1 })
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(runner.runs[0].context == nil)
}

@MainActor @Test func aDismissedOrClearedContextReachesNoRun() async throws {
    let (session, runner) = session()
    session.captureContext(Task { mail })
    #expect(await eventually { session.context == mail })
    session.dismissContext()
    #expect(session.context == nil)
    session.open(CommandRun(.runAgent, .invoked, text: "one"))
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.runs[0].context == nil)

    // Dismissed while still capturing: the capture's result never shows.
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    session.captureContext(
        Task {
            for await _ in gate { break }
            return mail
        })
    session.dismissContext()
    open.yield()
    session.open(CommandRun(.runAgent, .invoked, text: "two"))
    #expect(await eventually { runner.runs.count == 2 })
    #expect(runner.runs[1].context == nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(session.context == nil)

    // The next summon with nothing to capture clears the last one's.
    session.captureContext(Task { mail })
    #expect(await eventually { session.context == mail })
    session.captureContext(nil)
    #expect(session.context == nil)
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}

@MainActor @Test func aQuestionTypedAfterItsKeywordGetsTheContext() async throws {
    let runner = RecordingRunner()
    let registry = CommandRegistry(builtins: builtins)
    let session = PaletteSession(sources: [], runner: runner, registry: registry)
    let dispatcher = ActionDispatcher(registry: registry, effects: NoEffects())
    session.captureContext(Task { mail })
    // `ai ` opens Run Agent waiting for its question; Return submits the field through the dispatcher.
    session.query = "ai "
    session.query = "summarise this"
    let action = try #require(session.top.target?.actions.first)
    guard case .open(let run) = dispatcher.perform(action, as: .host, in: ActionContext()) else {
        Issue.record("expected Run Agent to open")
        return
    }
    session.open(run)
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.runs[0].text == "summarise this")
    #expect(runner.runs[0].context == mail)
}
