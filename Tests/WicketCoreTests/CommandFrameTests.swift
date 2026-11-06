import Foundation
import Synchronization
import Testing

@testable import WicketCore

// Command frames: fed by a stream of results from a `CommandRunner`, opened by keyword or by an
// action, cancelled with their frame.

/// Hands out one stream per run, which the test drives through its continuation.
@MainActor
private final class FakeRunner: CommandRunner {
    struct Run {
        let invocation: Invocation
        let kind: RequestKind
        let continuation: AsyncThrowingStream<RunResult, any Error>.Continuation
    }

    private(set) var runs: [Run] = []
    private let ended = Mutex<Set<Int>>([])

    func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let index = runs.count
        continuation.onTermination = { [self] _ in ended.withLock { _ = $0.insert(index) } }
        runs.append(Run(invocation: invocation, kind: kind, continuation: continuation))
        return stream
    }

    /// The texts sent, in order.
    var texts: [String] { runs.map(\.invocation.text) }

    func wasEnded(_ run: Int) -> Bool { ended.withLock { $0.contains(run) } }
}

private struct Failure: Error, CustomStringConvertible {
    var description: String { "GitHub rejected the token" }
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

private func row(_ title: String, actions: [Item.Action] = []) -> Item {
    Item(id: "ext:x/y:" + title, title: title, icon: .symbol(name: "doc"), actions: actions)
}

private let search = RegisteredCommand(
    id: .extension("unicode", "search"), title: "Search Unicode Characters", icon: .symbol(name: "character"),
    keyword: "uc", mode: .live, placeholder: "Character name")
private let reviews = RegisteredCommand(
    id: .extension("github-prs", "review-requests"), title: "GitHub Review Requests",
    icon: .symbol(name: "arrow.triangle.pull"), keyword: "prr")
private let quit = RegisteredCommand(
    id: .extension("quit-apps", "quit"), title: "Quit App", icon: .symbol(name: "xmark"), keyword: "q",
    isListed: false)

@MainActor
private func session(debounce: Duration = .zero) -> (PaletteSession, FakeRunner, [PaletteSession.Request]) {
    let registry = CommandRegistry()
    registry.setExtensionCommands([search, reviews, quit])
    let runner = FakeRunner()
    return (
        PaletteSession(sources: [], runner: runner, registry: registry, liveDebounce: debounce), runner, []
    )
}

@MainActor
private func content(_ session: PaletteSession) -> CommandFrame? {
    if case .command(let command) = session.top.content { command } else { nil }
}

@MainActor
private func titles(_ session: PaletteSession) -> [String] {
    session.top.list?.items.map(\.title) ?? []
}

@MainActor @Test func aKeywordAndASpaceOpenTheCommandWithTheRestAsItsQuery() async {
    let (session, runner, _) = session()
    session.query = "UC heart"
    #expect(session.frames.count == 2)
    // The root keeps the keyword, so going back shows where the user came from.
    #expect(session.frames[0].query == "UC")
    #expect(session.query == "heart")
    #expect(session.top.isLoading)
    #expect(content(session)?.screen == nil)
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.texts == ["heart"])
    #expect(runner.runs[0].kind == .query)

    runner.runs[0].continuation.yield(.list([row("Heavy Black Heart")]))
    runner.runs[0].continuation.finish()
    #expect(await eventually { !session.top.isLoading })
    #expect(titles(session) == ["Heavy Black Heart"])

    #expect(session.escape() == .clearedText)
    #expect(session.escape() == .popped)
    #expect(session.query == "UC")
}

@MainActor @Test func hiddenCommandsHaveNoKeyword() {
    let (session, _, _) = session()
    session.query = "q x"
    #expect(session.frames.count == 1)
}

@MainActor @Test func liveQueriesSupersedeAndCoalesce() async {
    let (session, runner, _) = session(debounce: .milliseconds(20))
    session.query = "uc "
    #expect(await eventually { runner.texts == [""] })
    // Nothing typed and nothing to show: the bare pill, whose placeholder says what to type.
    runner.runs[0].continuation.yield(.list([]))
    #expect(await eventually { session.top.isCompact })

    for text in ["g", "gr", "gri"] { session.query = text }
    #expect(await eventually { runner.texts == ["", "gri"] })
    #expect(runner.wasEnded(0))
    // The superseded run's late answer is dropped.
    runner.runs[0].continuation.yield(.list([row("Stale")]))
    runner.runs[1].continuation.yield(.list([row("Grinning Face"), row("Grinning Cat")]))
    #expect(await eventually { titles(session) == ["Grinning Face", "Grinning Cat"] })
    #expect(!session.top.isCompact)
}

@MainActor @Test func aLiveListKeepsItsSelectionUntilTheTextChanges() async {
    let (session, runner, _) = session()
    session.query = "uc cat"
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.list([row("A"), row("B")]))
    #expect(await eventually { titles(session) == ["A", "B"] })
    session.moveSelection(by: 1)
    // A second answer for the same text (a streaming producer) keeps the selection on its item.
    runner.runs[0].continuation.yield(.list([row("Z"), row("A"), row("B")]))
    #expect(await eventually { titles(session) == ["Z", "A", "B"] })
    #expect(session.top.list?.selectedItem?.title == "B")

    session.query = "cats"
    #expect(await eventually { runner.runs.count == 2 })
    runner.runs[1].continuation.yield(.list([row("A"), row("B")]))
    #expect(await eventually { titles(session) == ["A", "B"] })
    #expect(session.top.list?.selection == 0)
}

@MainActor @Test func onceListsFilterLocallyWithoutRunningAgain() async {
    let (session, runner, _) = session()
    session.query = "prr "
    #expect(session.query.isEmpty)
    #expect(await eventually { runner.runs.count == 1 })
    #expect(runner.texts == [""])
    // Typed before the list arrives: it opens filtered.
    session.query = "login"
    runner.runs[0].continuation.yield(
        .list([row("Bump Swift to 6.4"), row("Fix login timeout"), row("Login page")]))
    runner.runs[0].continuation.finish()
    #expect(await eventually { !titles(session).isEmpty })
    #expect(titles(session) == ["Login page", "Fix login timeout"])

    let generation = session.top.generation
    session.query = "swift"
    #expect(titles(session) == ["Bump Swift to 6.4"])
    session.query = ""
    #expect(titles(session) == ["Bump Swift to 6.4", "Fix login timeout", "Login page"])
    #expect(session.top.generation == generation)
    #expect(runner.runs.count == 1)
    // An empty list is a screen of its own ("No Results"), never the bare pill.
    session.query = "zzz"
    #expect(titles(session).isEmpty)
    #expect(!session.top.isCompact)
}

@MainActor @Test func anActionOpensItsFrameWhenTheFirstContentArrives() async {
    let (session, runner, _) = session()
    let run = CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query)
    session.open(run)
    #expect(session.opening == run)
    #expect(session.frames.count == 1)
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.answer(row("Week 45", actions: [.copy(text: "Week 45")])))
    #expect(await eventually { session.frames.count == 2 })
    #expect(session.opening == nil)
    #expect(titles(session) == ["Week 45"])
    #expect(session.top.target?.actions == [.copy(text: "Week 45")])
    // Still running until the stream ends.
    #expect(session.top.isLoading)
    runner.runs[0].continuation.finish()
    #expect(await eventually { !session.top.isLoading })
}

@MainActor @Test func aLiveCommandOpenedByAnActionSearchesWithItsArgs() async {
    let (session, runner, _) = session()
    let args: [String: JSONValue] = ["repo": .string("acme/web")]
    session.open(
        CommandRun(command: search, invocation: Invocation(command: search.id, args: args), kind: .action))
    #expect(session.frames.count == 2)
    session.query = "x"
    #expect(await eventually { runner.texts.last == "x" })
    #expect(runner.runs.allSatisfy { $0.invocation.args == args && $0.kind == .query })
}

@MainActor @Test func aFirstCloseClosesThePaletteWithoutAFrame() async {
    var (session, runner, requests) = session()
    session.onRequest = { requests.append($0) }
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query))
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.close(message: "Dark mode on"))
    #expect(await eventually { !requests.isEmpty })
    #expect(requests == [.close(message: "Dark mode on")])
    #expect(session.frames.count == 1)
    #expect(session.opening == nil)
}

@MainActor @Test func aReloadRunsTheFrameItCameFromAgain() async {
    var (session, runner, requests) = session()
    session.onRequest = { requests.append($0) }
    session.query = "prr "
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.list([row("Mail"), row("Safari"), row("Notes")]))
    runner.runs[0].continuation.finish()
    #expect(await eventually { titles(session).count == 3 })
    session.moveSelection(by: 1)
    #expect(session.top.list?.selectedItem?.title == "Safari")

    let action = Invocation(command: quit.id, args: ["pid": .integer(7)])
    session.open(CommandRun(command: quit, invocation: action, kind: .action))
    #expect(await eventually { runner.runs.count == 2 })
    #expect(runner.runs[1].kind == .action)
    runner.runs[1].continuation.yield(.reload(message: "Quit Safari"))
    #expect(await eventually { runner.runs.count == 3 })
    #expect(requests == [.message("Quit Safari")])
    #expect(session.frames.count == 2)
    #expect(runner.runs[2].invocation == runner.runs[0].invocation)

    // The list comes back without Safari; the selection stays on its row.
    runner.runs[2].continuation.yield(.list([row("Mail"), row("Notes")]))
    #expect(await eventually { titles(session) == ["Mail", "Notes"] })
    #expect(session.top.list?.selectedItem?.title == "Notes")
}

@MainActor @Test func aReloadFromTheFramesOwnRunGoesBack() async {
    var (session, runner, requests) = session()
    session.onRequest = { requests.append($0) }
    session.query = "uc x"
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.reload(message: nil))
    #expect(await eventually { session.frames.count == 1 })
    #expect(requests.isEmpty)
}

@MainActor @Test func failuresShowInTheFrame() async {
    let (session, runner, _) = session()
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query))
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.finish(throwing: Failure())
    #expect(await eventually { session.frames.count == 2 })
    #expect(!session.top.isLoading)
    #expect(
        content(session)?.screen
            == .detail(
                Detail(
                    title: "GitHub Review Requests Failed", markdown: "GitHub rejected the token",
                    metadata: [.init(label: "Command", value: "github-prs/review-requests")])))
    #expect(session.top.target?.actions == [.copy(text: "GitHub rejected the token")])

    // A live command's next query replaces the failure.
    #expect(session.escape() == .popped)
    session.query = "uc a"
    #expect(await eventually { runner.runs.count == 2 })
    runner.runs[1].continuation.finish(throwing: Failure())
    #expect(await eventually { content(session)?.screen != nil })
    session.query = "ab"
    #expect(await eventually { runner.runs.count == 3 })
    runner.runs[2].continuation.yield(.list([row("AB")]))
    #expect(await eventually { titles(session) == ["AB"] })
}

@MainActor @Test func aRunThatSendsNothingFails() async {
    let (session, runner, _) = session()
    session.query = "prr "
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.finish()
    #expect(await eventually { content(session)?.screen != nil })
    guard case .detail(let detail) = content(session)?.screen else {
        Issue.record("expected a failure")
        return
    }
    #expect(detail.markdown == "The command finished without a result.")
}

@MainActor @Test func streamedContentReplacesTheFrameInPlace() async {
    // The mechanism a streaming AI answer uses: a growing detail, element after element.
    let (session, runner, _) = session()
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query))
    #expect(await eventually { runner.runs.count == 1 })
    var markdown = ""
    var frame: Frame.ID?
    for word in ["Paris", " is", " the", " capital."] {
        markdown += word
        runner.runs[0].continuation.yield(.detail(Detail(title: "Answer", markdown: markdown)))
        #expect(await eventually { session.top.target?.actions == [.copy(text: markdown)] })
        frame = frame ?? session.top.id
        #expect(session.top.id == frame)
        #expect(session.top.isLoading)
    }
    #expect(session.frames.count == 2)
    #expect(session.top.generation == 1)
    runner.runs[0].continuation.finish()
    #expect(await eventually { !session.top.isLoading })
}

@MainActor @Test func runsEndWithTheirFrame() async {
    let (session, runner, _) = session()
    // Escape stops a command still being opened.
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query))
    #expect(await eventually { runner.runs.count == 1 })
    #expect(session.escape() == .cancelledOpening)
    #expect(session.opening == nil)
    #expect(await eventually { runner.wasEnded(0) })
    runner.runs[0].continuation.yield(.list([row("Late")]))
    try? await Task.sleep(for: .milliseconds(5))
    #expect(session.frames.count == 1)

    // Popping a frame ends its run.
    session.query = "uc a"
    #expect(await eventually { runner.runs.count == 2 })
    session.query = ""
    #expect(await eventually { runner.runs.count == 3 })
    #expect(session.escape() == .popped)
    #expect(await eventually { runner.wasEnded(2) })

    // Dismissing ends everything, including an opening.
    session.query = "prr "
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .query))
    #expect(await eventually { runner.runs.count == 5 })
    session.reset()
    #expect(await eventually { runner.wasEnded(3) && runner.wasEnded(4) })
    #expect(session.frames.count == 1)
    #expect(session.opening == nil)
    #expect(session.top.isCompact)
}

@MainActor @Test func withoutARunnerAFrameSaysSo() async {
    let registry = CommandRegistry()
    registry.setExtensionCommands([reviews])
    let session = PaletteSession(sources: [], registry: registry)
    session.query = "prr "
    #expect(await eventually { content(session)?.screen != nil })
    #expect(!session.top.isLoading)
}

// MARK: Commands that leave the registry

@MainActor @Test func stoppingACommandPopsItsFrameAndEndsItsRun() async {
    let (session, runner, _) = session()
    session.query = "prr"
    session.query = "prr "
    #expect(await eventually { runner.runs.count == 1 })
    runner.runs[0].continuation.yield(.list([row("PR 1", actions: [.copy(text: "1")])]))
    #expect(await eventually { session.top.list?.items.count == 1 })
    session.push(Detail(title: "PR 1", markdown: "", actions: []))
    #expect(session.frames.count == 3)

    #expect(!session.stopCommands { $0 == search.id })
    #expect(session.frames.count == 3)
    #expect(session.stopCommands { $0 == reviews.id })
    // The detail it pushed goes with it, back to where it was opened from.
    #expect(session.frames.count == 1)
    #expect(session.query == "prr")
    #expect(await eventually { runner.wasEnded(0) })
}

@MainActor @Test func stoppingACommandCancelsItsOpening() async {
    let (session, runner, _) = session()
    session.open(CommandRun(command: reviews, invocation: Invocation(command: reviews.id), kind: .action))
    #expect(session.opening != nil)
    #expect(await eventually { runner.runs.count == 1 })
    #expect(session.stopCommands { $0 == reviews.id })
    #expect(session.opening == nil)
    #expect(session.frames.count == 1)
    #expect(await eventually { runner.wasEnded(0) })
    // A late result of the cancelled run shows nothing.
    runner.runs[0].continuation.yield(.list([row("late")]))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(session.frames.count == 1)
}
