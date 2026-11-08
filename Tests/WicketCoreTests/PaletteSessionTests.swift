import Foundation
import Synchronization
import Testing

@testable import WicketCore

private func item(_ title: String, score: Double = 0, actions: [Item.Action] = []) -> Item {
    Item(id: "test:" + title, title: title, icon: .symbol(name: "doc"), score: score, actions: actions)
}

private final class Terminations: Sendable {
    let texts = Mutex<Set<String>>([])
}

/// A source with instant results by query text and, if `slow`, one stream per query whose
/// continuation the test drives.
@MainActor
private final class FakeSource: ResultSource {
    let id: String
    let instantResults: [String: [Item]]
    let slow: Bool
    private(set) var streams: [String: AsyncStream<[Item]>.Continuation] = [:]
    let terminated = Terminations()

    init(_ id: String, instant: [String: [Item]] = [:], slow: Bool = false) {
        self.id = id
        instantResults = instant
        self.slow = slow
    }

    func instant(_ query: Query) -> [Item] { instantResults[query.text] ?? [] }

    func updates(_ query: Query) -> AsyncStream<[Item]>? {
        guard slow else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: [Item].self)
        let text = query.text
        continuation.onTermination = { [terminated] _ in terminated.texts.withLock { _ = $0.insert(text) } }
        streams[text] = continuation
        return stream
    }

    func wasTerminated(_ text: String) -> Bool { terminated.texts.withLock { $0.contains(text) } }
}

/// Lets the session's tasks run until `condition` holds; false if it never does.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func titles(_ session: PaletteSession) -> [String] {
    MainActor.assumeIsolated { session.top.list?.items.map(\.title) ?? [] }
}

private let page = Detail(title: "Page", markdown: "# Page", actions: [.copy(text: "x")])

@MainActor @Test func instantResultsArriveWithTheKeystroke() {
    let session = PaletteSession(sources: [FakeSource("apps", instant: ["sa": [item("Safari")]])])
    #expect(session.top.isCompact)
    session.query = "sa"
    #expect(titles(session) == ["Safari"])
    #expect(!session.top.isCompact)
    #expect(session.top.target?.item?.title == "Safari")
}

@MainActor @Test func slowResultsApplyWhileCurrent() async {
    let files = FakeSource("files", slow: true)
    let session = PaletteSession(sources: [FakeSource("apps", instant: ["a": [item("A", score: 9)]]), files])
    session.query = "a"
    #expect(session.top.isLoading)
    files.streams["a"]?.yield([item("File")])
    #expect(await eventually { titles(session) == ["A", "File"] })
    files.streams["a"]?.finish()
    #expect(await eventually { !session.top.isLoading })
}

@MainActor @Test func aNewQueryCancelsTheOldWork() async {
    let files = FakeSource("files", slow: true)
    let session = PaletteSession(sources: [files])
    session.query = "a"
    let old = files.streams["a"]
    session.query = "ab"
    #expect(await eventually { files.wasTerminated("a") })
    old?.yield([item("Stale")])
    files.streams["ab"]?.yield([item("Fresh")])
    #expect(await eventually { titles(session) == ["Fresh"] })
    #expect(session.top.isLoading)
}

/// Escape goes up one layer: a pushed frame pops whatever its text, then the root's text clears,
/// and only at an empty root is there nothing left (the palette closes).
@MainActor @Test func backGoesUpOneLayerAtATime() {
    let session = PaletteSession(sources: [FakeSource("apps", instant: ["a": [item("A")]])])
    session.query = "a"
    session.push(page, from: .host)
    session.query = "typed"
    #expect(session.back())
    // The root search comes back as it was.
    #expect(session.frames.count == 1)
    #expect(session.query == "a")
    #expect(titles(session) == ["A"])
    #expect(session.back())
    #expect(session.query == "")
    #expect(!session.back())
}

@MainActor @Test func aPushedFrameIsNeverCompact() {
    let session = PaletteSession(sources: [])
    session.push(page, from: .host)
    #expect(session.query.isEmpty)
    #expect(!session.top.isCompact)
    // A page's list holds its targets: none in plain text.
    #expect(session.top.list?.items.isEmpty == true)
}

@MainActor @Test func theRootKeepsLoadingUnderAPushedFrame() async {
    let files = FakeSource("files", slow: true)
    let session = PaletteSession(sources: [files])
    session.query = "a"
    session.push(page, from: .host)
    files.streams["a"]?.yield([item("File")])
    #expect(await eventually { session.frames[0].list?.items.map(\.title) == ["File"] })
    #expect(!files.wasTerminated("a"))
}

@MainActor @Test func dismissingCancelsEverything() async {
    let files = FakeSource("files", slow: true)
    let session = PaletteSession(sources: [files])
    session.query = "a"
    session.push(page, from: .host)
    session.reset()
    #expect(session.frames.count == 1)
    #expect(session.query.isEmpty)
    #expect(session.top.isCompact)
    #expect(await eventually { files.wasTerminated("a") })
    files.streams["a"]?.yield([item("Late")])
    await Task.yield()
    #expect(titles(session).isEmpty)
    #expect(!session.top.isLoading)
}

@MainActor @Test func selectionMovesOnlyInTheTopFrame() {
    let session = PaletteSession(sources: [
        FakeSource("apps", instant: ["a": [item("A", score: 2), item("B")]])
    ])
    session.query = "a"
    session.moveSelection(by: 1)
    session.push(page, from: .host)
    session.moveSelection(by: -1)
    session.back()
    #expect(session.top.list?.selectedItem?.title == "B")
}

@MainActor @Test func refreshKeepsTheSelection() {
    let session = PaletteSession(sources: [
        FakeSource("apps", instant: ["a": [item("A", score: 2), item("B")]])
    ])
    session.query = "a"
    session.moveSelection(by: 1)
    session.refresh()
    #expect(session.top.list?.selectedItem?.title == "B")
}

@Test func detailsActOnTheirOwnActions() {
    #expect(ActionTarget(detail: page, text: "x", in: .host).actions == [.copy(text: "x")])
    #expect(ActionTarget(detail: page, text: "x", in: .host).item == nil)
    // Without actions, Return copies the page as text.
    #expect(
        ActionTarget(detail: Detail(markdown: "# Hi"), text: "Hi", in: .host).actions == [.copy(text: "Hi")])
}

/// An agent's page has no actions of its own: every action on it is Wicket's, the screen's. Return
/// runs the first (Copy Answer) and ⌘↩ the one the screen names (Follow Up), selected row or not.
@Test func anAgentsPageActsThroughTheScreensActions() {
    let copy = Item.Action.copy(text: "answer", title: "Copy Answer")
    let followUp = Item.Action.run(command: .builtin("follow-up"), title: "Follow Up")
    let context = ScreenContext(authority: .agent, actions: [copy, followUp], secondary: 1)
    let page = ActionTarget(detail: Detail(markdown: "# Hi"), text: "Hi", in: context)
    #expect(page.actions.isEmpty)
    #expect(page.primary == .screen(0))
    #expect(page.secondary == .screen(1))
    #expect(page.action(at: page.primary)?.action == copy)
    let row = ActionTarget(item: item("A"), in: context)
    #expect(row.primary == .action(0))
    #expect(row.secondary == .screen(1))
    #expect(row.action(at: row.secondary)?.authority == .host)
}

/// ⌘↩ is the screen's first action when it has any, else the second action as before.
@Test func theSecondaryChordPrefersTheScreensAction() {
    let row = Item(
        id: "a", title: "A", icon: .symbol(name: "doc"), actions: [.copy(text: "1"), .copy(text: "2")])
    #expect(ActionTarget(item: row, in: .host).secondary == .action(1))
    let followUp = Item.Action.copy(text: "follow", title: "Follow Up")
    let target = ActionTarget(item: row, in: ScreenContext(authority: .agent, actions: [followUp]))
    #expect(target.secondary == .screen(0))
    #expect(target.action(at: .screen(0))! == (followUp, .host))
    #expect(target.action(at: .action(1))! == (.copy(text: "2"), .agent))
}
