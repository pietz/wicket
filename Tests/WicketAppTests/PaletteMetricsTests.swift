import Foundation
import Testing
import WicketCore

@testable import WicketApp

/// The card under the pill: a list is sized from its rows, a detail from its measured content, the
/// action panel needs room, and nothing is ever taller than `maxCardHeight`.
@MainActor
struct PaletteMetricsTests {
    let source = StaticSource("test", items: [])
    let runner = FakeRunner()
    let session: PaletteSession

    init() {
        session = PaletteSession(sources: [source], runner: runner, liveDebounce: .zero)
    }

    private func search(_ items: [Item]) -> Frame {
        source.items = items
        if session.query == "x" { session.refresh() } else { session.query = "x" }
        return session.top
    }

    private func card(_ frame: Frame, menu: ActionMenu? = nil, detail: CGFloat? = nil) -> CGFloat? {
        PaletteMetrics.cardHeight(for: frame, actionMenu: menu, detailHeight: detail)
    }

    @Test func emptyRootHasNoCard() {
        #expect(card(session.top) == 0)
        #expect(card(search([])) == 0)
    }

    /// Rows of 40 with 2 between them, 8 of inset above and below, then the divider and the footer.
    @Test func listFitsItsRows() {
        #expect(card(search([item("a")])) == 91)
        #expect(card(search([item("a"), item("b"), item("c")])) == 175)
        let many = (0..<30).map { item("\($0)") }
        #expect(card(search(many)) == PaletteMetrics.maxCardHeight)
    }

    @Test func answerOnTopIsTaller() {
        let answer = item("= 4", relevance: .answer)
        #expect(card(search([item("b")])) == 91)
        #expect(card(search([answer, item("b")])) == 153)  // 133 for two plain rows.
    }

    @Test func actionMenuNeedsRoom() {
        let actions: [Item.Action] = (0..<5).map { .copy(text: "\($0)") }
        let frame = search([item("a", actions: actions)])
        let menu = ActionMenu(target: ActionTarget(item: frame.list!.items[0]), pasteTarget: nil)
        let panel = ActionPanel.height(rows: 5) + ActionPanel.clearance
        #expect(card(frame, menu: menu) == panel.rounded(.up))
        #expect(card(frame, menu: menu)! > card(frame)!)
        // A list taller than the panel keeps its own height.
        let tall = search((0..<7).map { item("\($0)", actions: actions) })
        #expect(card(tall, menu: menu) == card(tall))
    }

    @Test func detailFitsItsMeasuredContent() {
        session.push(Detail(title: "Page", markdown: "# Page", actions: []))
        #expect(card(session.top) == nil)  // Not laid out yet: keep the card.
        #expect(card(session.top, detail: 200) == 235)
        #expect(card(session.top, detail: 2000) == PaletteMetrics.maxCardHeight)
    }

    @Test func commandFrameWaitsForContent() async {
        let live = command("search", mode: .live)
        session.open(CommandRun(command: live, invocation: Invocation(command: live.id), kind: .query))
        #expect(card(session.top) == nil)
        #expect(await eventually { runner.count[live.id] == 1 })

        // A live command with an empty query and no results is the bare pill.
        runner.runs[live.id]?.yield(.list([]))
        #expect(await eventually { session.top.isCompact })
        #expect(card(session.top) == 0)

        // With a query, an empty list says so in one row.
        session.query = "q"
        #expect(await eventually { runner.count[live.id] == 2 })
        runner.runs[live.id]?.yield(.list([]))
        #expect(await eventually { !session.top.isCompact && session.top.list != nil })
        #expect(card(session.top) == 91)
    }
}
