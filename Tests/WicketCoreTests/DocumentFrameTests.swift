import Foundation
import Testing

@testable import WicketCore

// A page's markup in a frame: its targets as the frame's rows in reading order, none selected until
// the arrows move; a page of rows behaving as a list; typing on a document starting Follow Up.

@MainActor
private final class Runner: CommandRunner {
    var continuations: [AsyncThrowingStream<RunResult, any Error>.Continuation] = []

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        continuations.append(continuation)
        return stream
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

private let followUpID = CommandID.builtin("follow-up")
private let followUp = RegisteredCommand(
    id: followUpID, title: "Follow Up", icon: .symbol(name: "sparkles"), isListed: false, input: .submitText)
private let page = RegisteredCommand(
    id: .extension("weather", "today"), title: "Weather", icon: .symbol(name: "cloud"))

/// A session showing `markdown` as the page `page` sent, under `context`.
@MainActor
private func showing(_ markdown: String, _ context: ScreenContext = .host) async -> PaletteSession {
    let registry = CommandRegistry(builtins: builtins + [followUp])
    registry.setExtensionCommands([page])
    let runner = Runner()
    let session = PaletteSession(sources: [], runner: runner, registry: registry, liveDebounce: .zero)
    session.open(CommandRun(page, .invoked))
    _ = await eventually { runner.continuations.count == 1 }
    runner.continuations[0].yield(.show(.detail(Detail(title: "Page", markdown: markdown)), context))
    runner.continuations[0].finish()
    _ = await eventually { session.frames.count == 2 && !session.top.isLoading }
    return session
}

private let mixed = """
    Two sides.

    <columns>
    <column>
    <url href="https://a.example/1" title="A1"/>
    <url href="https://a.example/2" title="A2"/>
    </column>
    <card title="B" href="https://b.example">
    <stat label="From" value="$1"/>
    </card>
    </columns>

    <file path="/tmp/notes.txt"/>
    """

@MainActor @Test func aDocumentsTargetsAreItsRowsInReadingOrderNoneSelected() async {
    let session = await showing(mixed)
    #expect(session.top.isMeasured)
    #expect(session.top.document != nil)
    let titles = session.top.list?.items.map(\.title)
    // A column completely, then the next, then what follows the columns.
    #expect(titles == ["A1", "A2", "B", "notes.txt"])
    #expect(session.top.list?.selectedItem == nil)
    // With nothing selected, Return copies the page as text.
    #expect(session.top.target?.actions.first?.kind == .copy)

    session.moveSelection(by: 1)
    #expect(session.top.list?.selectedItem?.title == "A1")
    #expect(session.top.target?.item?.title == "A1")
    session.moveSelection(by: 2)
    #expect(session.top.list?.selectedItem?.title == "B")
    // Up past the first target selects nothing again.
    session.moveSelection(by: -2)
    session.moveSelection(by: -1)
    #expect(session.top.list?.selectedItem == nil)
    session.moveSelection(by: -1)
    #expect(session.top.list?.selectedItem == nil)
}

@MainActor @Test func aPageOfRowsIsAListThatFilters() async {
    let session = await showing(
        """
        <list title="Files">
        <file path="/tmp/alpha.txt"/>
        <file path="/tmp/beta.txt"/>
        </list>
        """)
    #expect(!session.top.isMeasured)
    #expect(session.top.listing?.sections.map(\.title) == ["Files"])
    #expect(session.top.list?.selectedItem?.title == "alpha.txt")
    #expect(session.typingAction == nil)
    session.query = "beta"
    #expect(session.top.list?.items.map(\.title) == ["beta.txt"])
}

/// Typing on an agent's answer continues the conversation through its host-owned screen action.
/// Ordinary lists filter, and pages without such an action take no text.
@MainActor @Test func typingOnADocumentStartsFollowUp() async {
    let follow = Item.Action.run(
        command: followUpID, args: ["conversation": .string("t")], title: "Follow Up")
    let copy = Item.Action.copy(text: "x", title: "Copy Answer")
    let retry = Item.Action.run(command: .runAgent, text: "question", title: "Retry")
    let answer = await showing(
        mixed, ScreenContext(authority: .agent, actions: [copy, follow, retry], secondary: 1))
    #expect(answer.typingAction == follow)
    // An agent's page has no actions of its own: Return copies the answer, ⌘↩ follows up.
    #expect(answer.top.target?.actions.isEmpty == true)
    #expect(answer.top.target?.primary == .screen(0))
    #expect(answer.top.target?.secondary == .screen(1))

    // Retry has its text, so it runs rather than waits: no Follow Up, no typing.
    let failed = await showing(mixed, ScreenContext(authority: .agent, actions: [retry, copy]))
    #expect(failed.typingAction == nil)
    let extensionPage = await showing(mixed)
    #expect(extensionPage.typingAction == nil)
}

@Test func aListThatSelectsNothingAtFirst() {
    let items = ["a", "b"].map { Item(id: $0, title: $0, icon: .symbol(name: "doc"), actions: []) }
    var list = ItemList(items, selectsFirst: false)
    #expect(!list.hasSelection && list.selectedItem == nil)
    list.moveSelection(by: -1)
    #expect(list.selectedItem == nil)
    list.moveSelection(by: 1)
    #expect(list.selectedItem?.id == "a")
    list.replace(with: items.reversed())
    #expect(list.selectedItem?.id == "a")
    list.replace(with: items, resettingSelection: true)
    #expect(list.selectedItem == nil)
    #expect(ItemList(items).selectedItem?.id == "a")
}

/// Copy and Paste take the whole page, however long: the part drawn natively as its text, what lies
/// past the markup and tail limits as written, to the last byte.
@MainActor @Test func aLongPagesPlainTextIsWhole() async {
    let line = String(repeating: "word ", count: 20) + "\n"
    let lines = (Markup.Limits.bytes + Markup.Limits.tailBytes) / line.utf8.count + 10
    let long =
        "<stat label=\"Total\" value=\"€420\"/>\n\n" + String(repeating: line, count: lines)
        + "<b>SENTINEL</b>"
    #expect(long.utf8.count > 128 * 1024)
    let text = Markup.plainText(long, home: URL(filePath: "/"))
    #expect(!text.contains("<stat"))
    #expect(text.hasSuffix(line + "<b>SENTINEL</b>"))
    // An extension's page without actions copies the same.
    let session = await showing(long)
    #expect(session.top.target?.actions.first == .copy(text: text))
}

/// A reply drawn entirely as rows still continues on typing; its rows remain selectable.
@MainActor @Test func anAnswerOfRowsContinuesOnTypingAndKeepsRowActions() async {
    let follow = Item.Action.run(
        command: followUpID, args: ["conversation": .string("t")], title: "Follow Up")
    let copy = Item.Action.copy(text: "x", title: "Copy Answer")
    let session = await showing(
        "<file path=\"/tmp/alpha.txt\"/>\n<file path=\"/tmp/beta.txt\"/>",
        ScreenContext(authority: .agent, actions: [copy, follow], secondary: 1))
    #expect(session.top.listing != nil)
    #expect(session.top.target?.item?.title == "alpha.txt")
    #expect(session.top.target?.screen == [copy, follow])
    #expect(session.typingAction == follow)
    session.moveSelection(by: 1)
    #expect(session.top.target?.item?.title == "beta.txt")
    #expect(session.top.target?.secondary == .screen(1))
}

/// A page pushed from an answer keeps the answer's screen actions and which of them ⌘↩ runs.
@MainActor @Test func aPushedPageKeepsTheAnswersSecondary() async {
    let follow = Item.Action.run(
        command: followUpID, args: ["conversation": .string("t")], title: "Follow Up")
    let copy = Item.Action.copy(text: "x", title: "Copy Answer")
    let session = await showing(
        mixed, ScreenContext(authority: .agent, actions: [copy, follow], secondary: 1))
    session.push(Detail(markdown: "More."), from: .agent)
    #expect(session.top.target?.screen == [copy, follow])
    #expect(session.top.target?.secondary == .screen(1))
}
