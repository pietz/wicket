import AppKit
import Foundation
import Testing
import WicketCore

@testable import WicketApp

/// The composed list's rules that don't need a window: when a summary is clipped, how its card is
/// sized, when Read Summary is offered and how the action panel groups the screen's actions.
@MainActor
struct ComposedListTests {
    let runner = FakeRunner()
    let session: PaletteSession

    init() {
        session = PaletteSession(sources: [], runner: runner, liveDebounce: .zero)
    }

    /// Shows `listing` in a command frame, as an extension's run would.
    private func show(_ listing: Listing, context: ScreenContext = .host) async -> Frame {
        let once = command("show")
        session.open(CommandRun(once, .invoked))
        #expect(await eventually { runner.count[once.id] == 1 })
        runner.runs[once.id]?.yield(.show(.list(listing), context))
        #expect(await eventually { session.frames.count == 2 })
        return session.top
    }

    private func rows(_ count: Int) -> [Item] { (0..<count).map { item("\($0)") } }

    /// Three lines show whole beside any number of rows; a longer summary is clipped to three,
    /// unless at most three rows leave it the room of the rows they don't take.
    @Test func summaryIsClippedOnlyWhenItDoesNotFit() {
        let line: CGFloat = 16
        #expect(!SummaryLayout.isClipped(lines: 3, rows: 20, lineHeight: line))
        #expect(SummaryLayout.isClipped(lines: 4, rows: 20, lineHeight: line))
        #expect(SummaryLayout.isClipped(lines: 4, rows: 4, lineHeight: line))
        // Three rows leave five rows of 42 pt: 13 more lines of 16 pt.
        #expect(SummaryLayout.lineLimit(rows: 3, lineHeight: line) == 16)
        #expect(!SummaryLayout.isClipped(lines: 16, rows: 3, lineHeight: line))
        #expect(SummaryLayout.isClipped(lines: 17, rows: 3, lineHeight: line))
        // No rows leave room as one does.
        #expect(
            SummaryLayout.lineLimit(rows: 0, lineHeight: line)
                == SummaryLayout.lineLimit(rows: 1, lineHeight: line))
        #expect(SummaryLayout.lines(height: 47, lineHeight: line) == 3)
    }

    /// The rows' part holds whole rows, at most eight, with the section titles among them.
    @Test func rowsHeightCountsTitlesAmongTheShownRows() {
        let step = PaletteMetrics.rowHeight + PaletteMetrics.rowSpacing
        let plain = PaletteMetrics.rowsHeight(count: 3, prominentFirst: false, headers: [])
        #expect(plain == 3 * step - PaletteMetrics.rowSpacing + 2 * PaletteMetrics.rowInset)
        let titled = PaletteMetrics.rowsHeight(count: 3, prominentFirst: false, headers: [true, false, true])
        #expect(titled == plain + 2 * PaletteMetrics.sectionHeaderHeight)
        // A title below the eighth row scrolls with it, so it doesn't count.
        let many = Array(repeating: false, count: 8) + [true]
        #expect(
            PaletteMetrics.rowsHeight(count: 30, prominentFirst: false, headers: many)
                == PaletteMetrics.rowsHeight(count: 8, prominentFirst: false, headers: []))
        // The capped plain list is the tallest card's rows.
        #expect(
            PaletteMetrics.rowsHeight(count: 30, prominentFirst: false, headers: []) + 1 + FooterBar.height
                == PaletteMetrics.maxCardHeight)
    }

    /// A list with a top waits for the top's measurement, then adds it to the rows and titles.
    @Test func cardAddsTheMeasuredTopAndTitles() async {
        let listing = Listing(
            sections: [.init(title: "A", items: rows(2)), .init(title: "B", items: [item("x")])],
            summary: "Three things.")
        let frame = await show(listing)
        #expect(PaletteMetrics.cardHeight(for: frame, actionMenu: nil, detailHeight: nil) == nil)
        let rowsHeight = PaletteMetrics.rowsHeight(
            count: 3, prominentFirst: false, headers: [true, false, true])
        let card = PaletteMetrics.cardHeight(for: frame, actionMenu: nil, detailHeight: nil, listTop: 40)
        #expect(card == (40 + rowsHeight + 1 + FooterBar.height).rounded(.up))
    }

    /// Eight whole rows still show under a top: the card grows past the plain cap by the top.
    @Test func longListUnderATopKeepsEightWholeRows() async {
        let frame = await show(Listing(rows(30), facts: [.init(label: "Total", value: "30")]))
        let card = PaletteMetrics.cardHeight(for: frame, actionMenu: nil, detailHeight: nil, listTop: 50)
        #expect(card == PaletteMetrics.maxCardHeight + 50)
    }

    /// Read Summary joins the screen's actions when the view clipped the summary or there are more
    /// facts than the strip shows, after the screen's own actions, and never takes ⌘↩ from the row.
    @Test func readSummaryIsOfferedWhenThereIsMore() async {
        let model = PaletteModel(sources: [], runner: runner, usageURL: scratchUsage())
        let once = command("show")
        let facts = (0..<5).map { Detail.Metadata(label: "L\($0)", value: "\($0)") }
        model.session.open(CommandRun(once, .invoked))
        #expect(await eventually { runner.count[once.id] == 1 })
        runner.runs[once.id]?.yield(
            .show(.list(Listing(rows(5), summary: "Long", facts: Array(facts.prefix(4))))))
        #expect(await eventually { model.session.frames.count == 2 })
        #expect(model.target?.screen.isEmpty == true)
        model.measureListTop(60, clipped: true, of: model.top.id)
        #expect(model.target?.screen.count == 1)
        #expect(model.target?.screen.first.map(ReadSummary.is) == true)
        #expect(model.target?.secondary == .action(1))
        let menu = model.actionMenu(for: model.target!)
        #expect(menu.rows.last?.presentation.title == "Read Summary")
        #expect(menu.lineCount == 2)  // The group's title and Read Summary; the row has no actions.

        // Unclipped, five facts still offer it; the page holds them all.
        runner.runs[once.id]?.yield(.show(.list(Listing(rows(5), summary: "Short", facts: facts))))
        #expect(await eventually { model.top.listing?.facts.count == 5 })
        model.measureListTop(60, clipped: false, of: model.top.id)
        guard case .detail(let page)? = model.target?.screen.last else {
            Issue.record("no Read Summary")
            return
        }
        #expect(page.markdown == "Short")
        #expect(page.metadata == facts)
    }

    /// The panel lists the row's actions, then the screen's under its title; ⌘↩ marks the
    /// secondary, which is the screen's first when it came with any.
    @Test func actionPanelGroupsTheScreensActions() {
        let followUp = Item.Action.copy(text: "follow", title: "Follow Up")
        let row = item("a", actions: [.copy(text: "1"), .copy(text: "2")])
        let target = ActionTarget(item: row, in: ScreenContext(authority: .agent, actions: [followUp]))
        let menu = ActionMenu(target: target, screenTitle: "Answer")
        #expect(menu.rows.map(\.id) == [.action(0), .action(1), .screen(0)])
        #expect(menu.lineCount == 4)
        #expect(menu.shortcut(for: .action(0)) == "↩")
        #expect(menu.shortcut(for: .screen(0)) == "⌘↩")
        #expect(menu.shortcut(for: .action(1)) == nil)

        let plain = ActionMenu(target: ActionTarget(item: row, in: .host))
        #expect(plain.lineCount == 2)
        #expect(plain.shortcut(for: .action(1)) == "⌘↩")
    }

    /// An agent's Open of an app is named as the Reveal it becomes, with the file it reveals.
    @Test func panelNamesTheResolvedAction() {
        let app = URL(filePath: "/Applications/Safari.app")
        let open = Item.Action.open(url: app, title: "Launch Safari")
        let named = ActionPresentation(open, resolved: .perform(.reveal(url: app)))
        #expect(named.symbol == ActionPresentation(.reveal(url: app)).symbol)
        #expect(named.detail == "Safari.app")
        #expect(ActionPresentation(open, resolved: .perform(open)).title == "Launch Safari")
    }

    @Test func pageMetadataGoesBesideOnlyATallerText() {
        #expect(DetailLayout.usesSidebar(text: nil, metadata: 100))
        #expect(DetailLayout.usesSidebar(text: 300, metadata: 120))
        #expect(!DetailLayout.usesSidebar(text: 120, metadata: 120))
        #expect(!DetailLayout.usesSidebar(text: 80, metadata: 200))
    }

    @Test func iconCacheKeysByFileAndSymbol() {
        #expect(
            IconCache.key(for: .file(url: URL(filePath: "/tmp/../tmp/x")))
                == IconCache.key(for: .file(url: URL(filePath: "/tmp/x"))))
        #expect(
            IconCache.key(for: .file(url: URL(filePath: "/a/doc")))
                != IconCache.key(for: .symbol(name: "/a/doc")))
        #expect(IconCache.key(for: .symbol(name: "globe")) == "symbol:globe")
    }

    @Test func fileDatesReadRelativeWithinAWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26
        #expect(
            FileDate.text(now.addingTimeInterval(-20), now: now, locale: locale, calendar: calendar) == "Now")
        let recent = FileDate.text(
            now.addingTimeInterval(-12 * 60), now: now, locale: locale, calendar: calendar)
        #expect(recent.contains("12") && recent.contains("ago"))
        let old = FileDate.text(
            now.addingTimeInterval(-20 * 86400), now: now, locale: locale, calendar: calendar)
        #expect(old == "Oct 6")
        let lastYear = FileDate.text(
            now.addingTimeInterval(-400 * 86400), now: now, locale: locale, calendar: calendar)
        #expect(lastYear.contains("2025"))
    }

    private func scratchUsage() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString).json")
    }
}
