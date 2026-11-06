import Foundation
import Testing

@testable import WicketCore

// Ask AI in the root: a static fallback row for any non-empty query, the `ai` prefix, its ranking,
// and the way from the row to its command's runner.

@MainActor
private func ask(_ text: String) -> [Item] {
    AskAISource().instant(Query(text: text, revision: 1))
}

@MainActor @Test func theRowIsOfferedForAnyNonEmptyQuery() throws {
    #expect(ask("").isEmpty)
    #expect(ask("   ").isEmpty)
    for text in ["s", "safari", "2+2", "what is the capital of peru?"] {
        let row = try #require(ask(text).first)
        #expect(ask(text).count == 1)
        #expect(row.title == "Ask AI")
        #expect(row.subtitle == text)
        #expect(row.relevance == .fallback)
        #expect(row.origin == AskAI.command)
        #expect(row.actions == [AskAI.action(asking: text)])
    }
    // The same id while typing, so the selection follows it.
    #expect(ask("ca").first?.id == ask("capital").first?.id)
}

@Test(arguments: [
    ("ai capital of peru", "capital of peru", Item.Relevance.exact),
    ("AI  capital of peru ", "capital of peru", .exact),
    ("ai", "ai", .fallback),
    ("aim high", "aim high", .fallback),
])
@MainActor func thePrefixAsksOnlyTheQuestionAtTheTop(text: String, prompt: String, relevance: Item.Relevance)
    throws
{
    let row = try #require(ask(text).first)
    #expect(row.subtitle == prompt)
    #expect(row.relevance == relevance)
    #expect(row.actions == [AskAI.action(asking: prompt)])
}

/// What Ask AI's hotkey types: the prefix and a space put the row at the top, waiting for a question.
@MainActor @Test func thePrefixAloneWaitsForAQuestion() throws {
    let row = try #require(ask("ai ").first)
    #expect(row.relevance == .exact)
    #expect(row.subtitle == "Type a question")
    #expect(row.actions.isEmpty)
}

@MainActor @Test func theRowRanksLastAndHabitNeverMovesIt() throws {
    let safari = Item(id: "apps:Safari", title: "Safari", icon: .symbol(name: "app"), score: 10, actions: [])
    let row = try #require(ask("saf").first)
    let ranked = Ranker.rank([row, safari], query: "saf", usage: { $0 == row.id ? 1000 : 0 })
    #expect(ranked.map(\.id) == ["apps:Safari", row.id])

    // In the user's fallback order, by its command.
    let web = Item(
        id: "web:search", title: "Search the Web", icon: .symbol(name: "globe"), relevance: .fallback,
        actions: [], origin: .builtin("web"))
    #expect(Ranker.rank([row, web], query: "saf", usage: { _ in 0 }).map(\.id) == [row.id, "web:search"])
    #expect(
        Ranker.rank(
            [row, web], query: "saf", usage: { _ in 0 }, fallbackOrder: [.builtin("web"), AskAI.command]
        )
        .map(\.id) == ["web:search", row.id])
}

@Test func thePromptTravelsAsTheRunsArgument() {
    #expect(AskAI.prompt(of: Invocation(command: AskAI.command, args: ["prompt": .string(" hi ")])) == "hi")
    #expect(AskAI.prompt(of: Invocation(command: AskAI.command, args: ["prompt": .string(" ")])) == nil)
    #expect(AskAI.prompt(of: Invocation(command: AskAI.command)) == nil)
}

/// Records each run and never answers.
@MainActor
private final class Recorder: CommandRunner {
    var runs: [Invocation] = []

    func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        return AsyncThrowingStream { _ in }
    }
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func openSettings() {}
    func quit() {}
}

@MainActor @Test func pickingTheRowOpensAskAIThroughTheRouter() async throws {
    let registry = CommandRegistry()
    let askAI = Recorder()
    let extensions = Recorder()
    let router = CommandRouter(builtins: [AskAI.command: askAI], extensions: extensions)
    let session = PaletteSession(sources: [AskAISource()], runner: router, registry: registry)
    // Hidden: reachable by its id only, never listed in the root search.
    #expect(registry.command(AskAI.command)?.isListed == false)
    #expect(registry.search("ask").isEmpty)

    session.query = "capital of peru"
    let target = try #require(session.top.target)
    let outcome = ActionDispatcher(registry: registry, effects: NoEffects()).perform(
        target.actions[0], in: ActionContext())
    guard case .open(let run) = outcome else {
        Issue.record("expected Ask AI to open its frame, got \(outcome)")
        return
    }
    #expect(run.command == BuiltinCommand.askAI.registered)
    session.open(run)
    #expect(session.opening == run)
    let deadline = ContinuousClock.now + .seconds(2)
    while askAI.runs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(askAI.runs.map(AskAI.prompt(of:)) == ["capital of peru"])
    #expect(extensions.runs.isEmpty)
}

@MainActor @Test func theRouterSendsEachRunToItsOwner() async {
    let askAI = Recorder()
    let extensions = Recorder()
    let router = CommandRouter(builtins: [AskAI.command: askAI], extensions: extensions)
    _ = router.run(Invocation(command: AskAI.command), kind: .action)
    _ = router.run(Invocation(command: .extension("unicode", "search"), text: "x"), kind: .query)
    #expect(askAI.runs.map(\.command) == [AskAI.command])
    #expect(extensions.runs.map(\.text) == ["x"])

    // A built-in nothing runs fails its frame rather than hanging it.
    var failure: (any Error)?
    do {
        for try await _ in router.run(Invocation(command: .builtin("nothing")), kind: .action) {}
    } catch {
        failure = error
    }
    #expect(failure.map { String(describing: $0) } == "Nothing runs this command.")
}
