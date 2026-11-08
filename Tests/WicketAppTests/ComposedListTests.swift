import AppKit
import Foundation
import Testing
import WicketCore

@testable import WicketApp

/// The composed list's and page's rules that don't need a window: how a card is sized under a
/// summary, when Load Images is offered and how the action panel groups the screen's actions.
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
        #expect(await eventually { !session.top.isStarting })
        return session.top
    }

    private func rows(_ count: Int) -> [Item] { (0..<count).map { item("\($0)") } }

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

    /// A list with a summary waits for its measurement, then adds it to the rows and titles.
    @Test func cardAddsTheMeasuredSummaryAndTitles() async {
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

    /// Eight whole rows still show under a summary: the card grows past the plain cap by the
    /// summary, up to four rows' worth; a taller summary scrolls with the rows.
    @Test func longListUnderASummaryKeepsEightWholeRows() async {
        let frame = await show(Listing(rows(30), summary: "<stat label=\"Total\" value=\"30\"/>"))
        #expect(frame.summary?.blocks.count == 1)
        let card = PaletteMetrics.cardHeight(for: frame, actionMenu: nil, detailHeight: nil, listTop: 50)
        #expect(card == PaletteMetrics.maxCardHeight + 50)
        let tall = PaletteMetrics.cardHeight(for: frame, actionMenu: nil, detailHeight: nil, listTop: 900)
        #expect(tall == PaletteMetrics.maxCardHeight + PaletteMetrics.maxListTop)
    }

    /// With online content off, a page holding web images offers Load Images among the screen's
    /// actions, naming the page; with it on, never. Running it is
    /// `AppRuntimeTests.loadImagesLoadsThePageItWasOfferedOn`.
    @Test func loadImagesIsOfferedWhileOnlineContentIsOff() async {
        let model = PaletteModel(sources: [], runner: runner, usageURL: scratchUsage())
        let once = command("show")
        model.session.open(CommandRun(once, .invoked))
        #expect(await eventually { runner.count[once.id] == 1 })
        runner.runs[once.id]?.yield(
            .show(.detail(Detail(markdown: "<image src=\"https://example.com/a.png\"/>\n\nText"))))
        runner.runs[once.id]?.finish()
        #expect(await eventually { model.session.frames.count == 2 && !model.top.isLoading })
        model.blockImages(1, of: model.top.id)
        #expect(model.target?.screen.isEmpty == true)
        model.showsOnlineContent = false
        let load = Item.Action.run(
            command: .loadImages, args: [PaletteModel.pageArg: .integer(model.top.id)], title: "Load Images")
        #expect(model.target?.screen == [load])
    }

    /// A page keeps the tallest it was laid out in its generation across a child page: going back
    /// and measuring shorter still sizes it by its tallest.
    @Test func aPageKeepsItsHeightAcrossAChildPage() async {
        let model = await model(showing: .detail(Detail(markdown: "Parent")))
        let parent = model.top.id
        model.measureDetail(300, of: parent)
        model.session.push(Detail(markdown: "Child"), from: .host)
        model.measureDetail(120, of: model.top.id)
        #expect(model.detailHeight == 120)
        model.session.back()
        model.measureDetail(200, of: parent)
        #expect(model.detailHeight == 300)
    }

    /// A model showing `screen`, as a command's run would.
    private func model(showing screen: Screen) async -> PaletteModel {
        let model = PaletteModel(sources: [], runner: runner, usageURL: scratchUsage())
        let once = command("show-\(runner.count.count)")
        model.session.open(CommandRun(once, .invoked))
        #expect(await eventually { runner.count[once.id] == 1 })
        runner.runs[once.id]?.yield(.show(screen))
        runner.runs[once.id]?.finish()
        #expect(await eventually { model.session.frames.count == 2 && !model.top.isLoading })
        return model
    }

    /// Navigation reveals a list's selected row, never the summary over it: Down on the only row,
    /// under a summary taller than the card, brings that row into view; going back up to the first
    /// row reveals it too; only Up on the first row shows the summary.
    @Test func arrowsRevealTheRowUnderATallSummary() async {
        let one = await model(showing: .list(Listing([item("only")], summary: "Long.")))
        one.moveSelection(by: 1)
        #expect(one.navigation?.moved == false && one.navigation?.showsListTop == false)
        one.moveSelection(by: -1)
        #expect(one.navigation?.showsListTop == true)

        let three = await model(showing: .list(Listing(rows(3), summary: "Long.")))
        three.moveSelection(by: 1)
        #expect(three.navigation?.moved == true)
        three.moveSelection(by: -1)
        #expect(three.navigation?.moved == true && three.navigation?.showsListTop == false)
        #expect(three.selection == 0)
    }

    /// On a page, an arrow that moves no selection scrolls the prose: Down past the last target
    /// with text below it, and Down on a page without targets.
    @Test func arrowsPastTheLastTargetScrollThePage() async {
        let page = await model(
            showing: .detail(Detail(markdown: "<url href=\"https://a.example\" title=\"A\"/>\n\nLong prose."))
        )
        page.moveSelection(by: 1)
        #expect(page.top.list?.selectedItem?.title == "A")
        #expect(page.navigation?.moved == true)
        page.moveSelection(by: 1)
        #expect(page.top.list?.selectedItem?.title == "A")
        #expect(page.navigation?.moved == false && page.navigation?.delta == 1)

        let prose = await model(showing: .detail(Detail(markdown: "Only prose.")))
        prose.moveSelection(by: 1)
        #expect(prose.navigation?.moved == false && prose.navigation?.delta == 1)
    }

    /// A page's card grows with its content and never shrinks while the same run feeds it (a
    /// streaming answer reflowing shorter for a moment); a new query of a live command starts over.
    @Test func aPageGrowsWithinARunAndStartsOverWithTheNext() async {
        let model = PaletteModel(sources: [], runner: runner, usageURL: scratchUsage())
        let live = command("live-page", input: .liveText)
        model.session.open(CommandRun(live, .invoked))
        #expect(await eventually { runner.count[live.id] == 1 })
        runner.runs[live.id]?.yield(.show(.detail(Detail(markdown: "Long"))))
        #expect(await eventually { model.top.isMeasured })
        #expect(model.detailHeight == nil)
        model.measureDetail(300, of: model.top.id)
        model.measureDetail(200, of: model.top.id)
        #expect(model.detailHeight == 300)
        // A view on its way out never sizes another frame's card.
        model.measureDetail(500, of: model.top.id + 1)
        #expect(model.detailHeight == 300)

        model.query = "short"
        #expect(model.detailHeight == nil)
        model.measureDetail(120, of: model.top.id)
        #expect(model.detailHeight == 120)
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
