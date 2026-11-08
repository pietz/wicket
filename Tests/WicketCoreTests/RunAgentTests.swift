import Foundation
import Testing

@testable import WicketCore

// Run Agent as an ordinary submit-text command: offered by the generic fallback source, reached by its
// keyword through the registry's rules, and run through the router only when its text is submitted.

/// Records each run and never answers.
@MainActor
private final class RecordingRunner: CommandRunner {
    var runs: [Invocation] = []

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        return AsyncThrowingStream { _ in }
    }
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}

/// Lets the session's tasks run until `condition` holds, for up to two seconds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
private func fallbacks(_ text: String, _ registry: CommandRegistry = CommandRegistry(builtins: builtins))
    -> [Item]
{
    FallbackSource(registry).instant(Query(text: text, generation: 1))
}

@MainActor @Test func theFallbackRowIsOfferedForAnyNonEmptyQuery() throws {
    #expect(fallbacks("").isEmpty)
    #expect(fallbacks("   ").isEmpty)
    for text in ["s", "safari", "2+2", "what is the capital of peru?"] {
        let row = try #require(fallbacks(text).first)
        #expect(fallbacks(text).count == 1)
        #expect(row.title == "Run Agent")
        #expect(row.subtitle == text)
        #expect(row.relevance == .fallback)
        #expect(row.origin == CommandID.runAgent)
        #expect(row.actions == [asking(text)])
    }
    // The same id while typing, so the selection follows it.
    #expect(fallbacks("ca").first?.id == fallbacks("capital").first?.id)
}

@MainActor @Test func everySubmitTextFallbackGetsARowAndNothingElseDoes() {
    let define = RegisteredCommand(
        id: .builtin("define"), title: "Define", icon: .symbol(name: "book"), isListed: false,
        input: .submitText, isFallback: true)
    // Only a submit-text command can take the query as its text.
    let notSubmit = RegisteredCommand(
        id: .builtin("live"), title: "Live", icon: .symbol(name: "bolt"), input: .liveText, isFallback: true)
    let registry = CommandRegistry(builtins: builtins + [define, notSubmit])
    #expect(fallbacks("paris", registry).map(\.origin) == [CommandID.runAgent, define.id])
    #expect(
        fallbacks("paris", registry)[1].actions == [
            .run(command: define.id, text: "paris", title: define.title)
        ])

    // With AI off, Run Agent isn't registered, so it isn't offered.
    registry.setAIEnabled(false)
    #expect(fallbacks("paris", registry).map(\.origin) == [define.id])
}

@MainActor @Test func theRowRanksLastAndHabitNeverMovesIt() throws {
    let safari = Item(id: "apps:Safari", title: "Safari", icon: .symbol(name: "app"), score: 10, actions: [])
    let row = try #require(fallbacks("saf").first)
    let ranked = Ranker.rank([row, safari], query: "saf", usage: { $0 == row.id ? 1000 : 0 })
    #expect(ranked.map(\.id) == ["apps:Safari", row.id])
}

@MainActor @Test func pickingTheRowRunsRunAgentOnTheQueryThroughTheRouter() async throws {
    let registry = CommandRegistry(builtins: builtins)
    let runAgent = RecordingRunner()
    let extensions = RecordingRunner()
    let router = CommandRouter(builtins: [Builtin(.runAgent, runner: runAgent)], extensions: extensions)
    let session = PaletteSession(sources: [FallbackSource(registry)], runner: router, registry: registry)
    // Not listed: the root offers it only as its fallback row.
    #expect(registry.command(CommandID.runAgent)?.isListed == false)
    #expect(registry.search("ask").isEmpty)

    session.query = "capital of peru"
    let target = try #require(session.top.target)
    let outcome = ActionDispatcher(registry: registry, effects: NoEffects()).perform(
        target.actions[0], as: .host, in: ActionContext())
    guard case .open(let run) = outcome else {
        Issue.record("expected Run Agent to open its frame, got \(outcome)")
        return
    }
    #expect(run == CommandRun(RegisteredCommand.runAgent, .invoked, text: "capital of peru"))
    session.open(run)
    #expect(session.top.run == run)
    #expect(session.top.isStarting)
    #expect(await eventually { !runAgent.runs.isEmpty })
    #expect(runAgent.runs.map(\.text) == ["capital of peru"])
    #expect(extensions.runs.isEmpty)
}

@MainActor @Test func theRouterSendsEachRunToItsOwner() async {
    let runAgent = RecordingRunner()
    let extensions = RecordingRunner()
    let router = CommandRouter(builtins: [Builtin(.runAgent, runner: runAgent)], extensions: extensions)
    _ = router.run(Invocation(command: CommandID.runAgent, text: "why"))
    _ = router.run(Invocation(command: .extension("unicode", "search"), text: "x"))
    #expect(runAgent.runs.map(\.command) == [CommandID.runAgent])
    #expect(extensions.runs.map(\.text) == ["x"])

    // A built-in nothing runs fails its frame rather than hanging it.
    var failure: (any Error)?
    do {
        for try await _ in router.run(Invocation(command: .builtin("nothing"))) {}
    } catch {
        failure = error
    }
    #expect(failure.map { String(describing: $0) } == "Nothing runs this command.")
}
