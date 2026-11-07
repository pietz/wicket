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
    }

    /// A search that found nothing says so in one row, but only once it finished: while slow sources
    /// still run the card stays as it is (the pill on a fresh summon), so typing never flashes it.
    @Test func rootWithNothingFoundSaysSoOnceFinished() async {
        #expect(card(search([])) == 95)

        let slow = SlowSource()
        let session = PaletteSession(sources: [slow], liveDebounce: .zero)
        session.query = "x"
        #expect(session.top.isLoading)
        #expect(card(session.top) == nil)
        slow.answer([])
        #expect(await eventually { !session.top.isLoading })
        #expect(card(session.top) == 95)
        session.query = ""
        #expect(card(session.top) == 0)
    }

    /// Rows of 40 with 2 between them, 8 of inset above and below, then the divider and the footer.
    @Test func listFitsItsRows() {
        #expect(card(search([item("a")])) == 95)
        #expect(card(search([item("a"), item("b"), item("c")])) == 179)
        let many = (0..<30).map { item("\($0)") }
        #expect(card(search(many)) == PaletteMetrics.maxCardHeight)
    }

    @Test func answerOnTopIsTaller() {
        let answer = item("= 4", relevance: .answer)
        #expect(card(search([item("b")])) == 95)
        #expect(card(search([answer, item("b")])) == 157)  // 137 for two plain rows.
    }

    /// An answer is 20 taller than a row, so a capped list with one on top is capped 20 higher: the
    /// answer and seven whole rows, never a row cut in half.
    @Test func cappedListWithAnswerShowsWholeRows() {
        let answer = item("= 4", relevance: .answer)
        let height = card(search([answer] + (0..<30).map { item("\($0)") }))!
        let extra = PaletteMetrics.answerRowHeight - PaletteMetrics.rowHeight
        #expect(height == PaletteMetrics.maxCardHeight + extra)
        let rows =
            height - 1 - FooterBar.height - 2 * PaletteMetrics.rowInset - PaletteMetrics.answerRowHeight
        let step = PaletteMetrics.rowHeight + PaletteMetrics.rowSpacing
        #expect(rows / step == 7)
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

    /// A long menu shows as many whole rows as the tallest card holds and scrolls the rest, so it
    /// never grows past the card over the pill.
    @Test func longActionMenuFitsTheCard() {
        let actions: [Item.Action] = (0..<40).map { .copy(text: "\($0)") }
        let frame = search([item("a", actions: actions)])
        let menu = ActionMenu(target: ActionTarget(item: frame.list!.items[0]), pasteTarget: nil)
        #expect(ActionPanel.maxRows > 5 && ActionPanel.maxRows < 40)
        #expect(ActionPanel.height(rows: 40) == ActionPanel.height(rows: ActionPanel.maxRows))
        #expect(ActionPanel.height(rows: 40) + ActionPanel.clearance <= PaletteMetrics.maxCardHeight)
        // One more row would not fit.
        let step = ActionPanel.rowHeight + ActionPanel.rowSpacing
        #expect(ActionPanel.height(rows: 40) + step + ActionPanel.clearance > PaletteMetrics.maxCardHeight)
        #expect(card(frame, menu: menu)! >= ActionPanel.height(rows: 40) + ActionPanel.clearance)
    }

    @Test func detailFitsItsMeasuredContent() {
        session.push(Detail(title: "Page", markdown: "# Page", actions: []))
        #expect(card(session.top) == nil)  // Not laid out yet: keep the card.
        #expect(card(session.top, detail: 200) == 235)
        #expect(card(session.top, detail: 2000) == PaletteMetrics.maxCardHeight)
    }

    /// A command's page is sized like a pushed one: by its measured content.
    @Test func aCommandsDetailFitsItsMeasuredContent() async {
        let once = command("show")
        session.open(CommandRun(once, .invoked))
        #expect(await eventually { runner.count[once.id] == 1 })
        runner.runs[once.id]?.yield(.show(.detail(Detail(title: "Page", markdown: "# Page"))))
        #expect(await eventually { session.frames.count == 2 })
        #expect(session.top.isMeasured)
        #expect(card(session.top) == nil)
        #expect(card(session.top, detail: 200) == 235)
    }

    @Test func commandFrameWaitsForContent() async {
        let live = command("search", input: .liveText, retry: .safeToRepeat)
        session.open(CommandRun(live, .invoked))
        #expect(card(session.top) == nil)
        #expect(await eventually { runner.count[live.id] == 1 })

        // A live command with an empty query and no results is the bare pill.
        runner.runs[live.id]?.yield(.show(.list([])))
        #expect(await eventually { session.top.isCompact })
        #expect(card(session.top) == 0)

        // With a query, an empty list says so in one row.
        session.query = "q"
        #expect(await eventually { runner.count[live.id] == 2 })
        runner.runs[live.id]?.yield(.show(.list([])))
        #expect(await eventually { !session.top.isCompact && session.top.list != nil })
        #expect(card(session.top) == 95)
    }

    /// A command waiting for its text is the bare pill, even over a root that had a card.
    @Test func aFrameWaitingForItsTextIsThePill() {
        #expect(card(search([item("a")])) == 95)
        let ask = command("ask", input: .submitText)
        session.open(CommandRun(ask, .invoked))
        #expect(session.frames.count == 2)
        #expect(card(session.top) == 0)
        session.query = "why"
        #expect(card(session.top) == 0)
    }
}
