import Foundation
import Testing

@testable import WicketCore

// Ask AI as an ordinary submit-text command: offered by the generic fallback source, reached by its
// keyword through the registry's rules, and run through the router only when its text is submitted.

/// Records each run and never answers.
@MainActor
private final class RecordingRunner: CommandRunner {
    var runs: [Invocation] = []
    var retries: [RetryPolicy] = []

    func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        retries.append(retry)
        return AsyncThrowingStream { _ in }
    }
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
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
        #expect(row.title == "Ask AI")
        #expect(row.subtitle == text)
        #expect(row.relevance == .fallback)
        #expect(row.origin == CommandID.askAI)
        #expect(row.actions == [asking(text)])
    }
    // The same id while typing, so the selection follows it.
    #expect(fallbacks("ca").first?.id == fallbacks("capital").first?.id)
}

@MainActor @Test func everySubmitTextFallbackGetsARowAndNothingElseDoes() {
    let web = RegisteredCommand(
        id: .builtin("web"), title: "Search the Web", icon: .symbol(name: "globe"), isListed: false,
        input: .submitText, isFallback: true)
    // Only a submit-text command can take the query as its text.
    let notSubmit = RegisteredCommand(
        id: .builtin("live"), title: "Live", icon: .symbol(name: "bolt"), input: .liveText, isFallback: true)
    let registry = CommandRegistry(builtins: builtins + [web, notSubmit])
    #expect(fallbacks("paris", registry).map(\.origin) == [CommandID.askAI, web.id])
    #expect(
        fallbacks("paris", registry)[1].actions == [.run(command: web.id, text: "paris", title: web.title)])

    // A fallback whose feature is off isn't registered, so it isn't offered.
    registry.setDisabledFeatures([.askAI])
    #expect(fallbacks("paris", registry).map(\.origin) == [web.id])
}

@MainActor @Test func theRowRanksLastInTheUsersFallbackOrderAndHabitNeverMovesIt() throws {
    let safari = Item(id: "apps:Safari", title: "Safari", icon: .symbol(name: "app"), score: 10, actions: [])
    let row = try #require(fallbacks("saf").first)
    let ranked = Ranker.rank([row, safari], query: "saf", usage: { $0 == row.id ? 1000 : 0 })
    #expect(ranked.map(\.id) == ["apps:Safari", row.id])

    let web = Item(
        id: "fallback:builtin:web", title: "Search the Web", icon: .symbol(name: "globe"),
        relevance: .fallback,
        actions: [], origin: .builtin("web"))
    #expect(
        Ranker.rank(
            [row, web], query: "saf", usage: { _ in 0 }, fallbackOrder: [.builtin("web"), CommandID.askAI]
        )
        .map(\.id) == [web.id, row.id])
}

@MainActor @Test func pickingTheRowRunsAskAIOnTheQueryThroughTheRouter() async throws {
    let registry = CommandRegistry(builtins: builtins)
    let askAI = RecordingRunner()
    let extensions = RecordingRunner()
    let router = CommandRouter(builtins: [Builtin(.askAI, runner: askAI)], extensions: extensions)
    let session = PaletteSession(sources: [FallbackSource(registry)], runner: router, registry: registry)
    // Not listed: the root offers it only as its fallback row.
    #expect(registry.command(CommandID.askAI)?.isListed == false)
    #expect(registry.search("ask").isEmpty)

    session.query = "capital of peru"
    let target = try #require(session.top.target)
    let outcome = ActionDispatcher(registry: registry, effects: NoEffects()).perform(
        target.actions[0], in: ActionContext())
    guard case .open(let run) = outcome else {
        Issue.record("expected Ask AI to open its frame, got \(outcome)")
        return
    }
    #expect(run == CommandRun(RegisteredCommand.askAI, .invoked, text: "capital of peru"))
    #expect(run.query == nil)
    session.open(run)
    #expect(session.opening == run)
    #expect(await eventually { !askAI.runs.isEmpty })
    #expect(askAI.runs.map(\.text) == ["capital of peru"])
    #expect(askAI.retries == [.never])
    #expect(extensions.runs.isEmpty)
}

@MainActor @Test func theRouterSendsEachRunToItsOwner() async {
    let askAI = RecordingRunner()
    let extensions = RecordingRunner()
    let router = CommandRouter(builtins: [Builtin(.askAI, runner: askAI)], extensions: extensions)
    _ = router.run(Invocation(command: CommandID.askAI, text: "why"), retry: .never)
    _ = router.run(Invocation(command: .extension("unicode", "search"), text: "x"), retry: .safeToRepeat)
    #expect(askAI.runs.map(\.command) == [CommandID.askAI])
    #expect(extensions.runs.map(\.text) == ["x"])

    // A built-in nothing runs fails its frame rather than hanging it.
    var failure: (any Error)?
    do {
        for try await _ in router.run(Invocation(command: .builtin("nothing")), retry: .never) {}
    } catch {
        failure = error
    }
    #expect(failure.map { String(describing: $0) } == "Nothing runs this command.")
}
