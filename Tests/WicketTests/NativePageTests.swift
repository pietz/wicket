import AppKit
import SwiftUI
import Testing

@testable import WicketApp

/// The kind of each block, for comparing a document's shape.
private func kinds(_ blocks: [PageBlock]) -> [String] {
  blocks.map {
    switch $0 {
    case .heading(let level, _): "h\(level)"
    case .paragraph: "p"
    case .list(let ordered, _, let items): "\(ordered ? "ol" : "ul")\(items.count)"
    case .quote: "quote"
    case .rule: "rule"
    case .table(let table): "table\(table.rows.count)x\(table.alignments.count)"
    case .code(_, let target): "code" + (target ?? "")
    case .rows(let items): "rows\(items.count)"
    case .properties(let items): "properties\(items.count)"
    case .tile: "tile"
    case .progresses(let items): "progress\(items.count)"
    case .badges(let items): "badges\(items.count)"
    case .card(let icon, let blocks): "card(\(icon ?? ""):\(kinds(blocks).joined(separator: ",")))"
    case .columns(let blocks): "columns(\(kinds(blocks).joined(separator: ",")))"
    case .fields(let controls): "fields\(controls.count)"
    case .chart(_, let pending): pending ? "chart…" : "chart"
    case .timeline(let timeline): "timeline\(timeline.spans.count)"
    }
  }
}

@MainActor @Test func theNativeDocumentReadsTheWholeVocabulary() {
  let body = """
    # Answer
    The **context** line with a [link](https://example.com) and `code`.

    - one
    - two

    1. first

    > quoted

    ---

    | Name | Size |
    |:-----|-----:|
    | a | 1 |
    | b | 2 |

    ```swift
    print(1)
    ```

    <row title="Open" open="https://apple.com"/>
    <row title="Copy" copy="x"/>
    <row label="Owner" value="You"/>
    <columns><tile label="A" title="1"/><tile label="B" title="2"/></columns>
    <card icon="bolt">
    ## Title
    Line one
    Line two
    </card>
    <progress label="Disk" value="70%" percent="70"/>
    <progress label="CPU" percent="20"/>
    Shipped <badge label="Healthy" tone="positive"/> today.

    <badge label="v2"/> <badge label="beta" tone="warning"/>
    <chart labels="a,b"><line name="x" values="1,2"/></chart>
    """
  let document = PageDocument(Page(body: body, runs: false), turn: "t", streaming: false)
  #expect(
    kinds(document.blocks) == [
      "h1", "p", "ul2", "ol1", "quote", "rule", "table2x2", "code#0", "rows2", "properties1",
      "columns(tile,tile)", "card(bolt:h2,p)", "progress2", "p", "badges2", "chart",
    ])
  guard case .paragraph(let line) = document.blocks[1], case .table(let table) = document.blocks[6],
    case .card(_, let card) = document.blocks[11], case .paragraph(let shipped) = document.blocks[13],
    case .rows(let rows) = document.blocks[8]
  else { return #expect(Bool(false)) }
  #expect(line.plain == "The context line with a link and code.")
  guard case .text(let text) = line.runs.first else { return #expect(Bool(false)) }
  #expect(text.runs.contains { $0.link == URL(string: "https://example.com") })
  #expect(text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
  #expect(text.runs.contains { $0.inlinePresentationIntent == .code })
  #expect(table.alignments == [.leading, .trailing])
  // Inside a card each line is its own.
  #expect(
    card.contains { if case .paragraph(let text) = $0 { text.plain == "Line one\nLine two" } else { false } })
  #expect(shipped.runs.contains { if case .badge(let item) = $0 { item.tone == "positive" } else { false } })
  // Targets keep the ids Page gave them, after the code block's.
  #expect(rows.map(\.target) == ["#1", "#2"])
}

@MainActor @Test func aStreamedTagWaitsAndAJavaScriptLinkIsText() {
  let streaming = PageDocument(
    Page(body: "Before\n<row title=\"Half", runs: false, streaming: true), turn: "t", streaming: true)
  #expect(kinds(streaming.blocks) == ["p"])
  let link = PageDocument(
    Page(body: "[x](javascript:alert(1)) <b>raw</b>", runs: false), turn: "t", streaming: false)
  guard case .paragraph(let text) = link.blocks.first, case .text(let runs) = text.runs.first else {
    return #expect(Bool(false))
  }
  #expect(runs.runs.allSatisfy { $0.link == nil } && text.plain == "x <b>raw</b>")
}

@MainActor @Test func theNativeRendererMeasuresAtOnceAndStreamingKeepsItsHeight() {
  let renderer = NativePageRenderer()
  let long = Page(
    body: (0..<40).map { "Paragraph \($0) of a long reply." }.joined(separator: "\n\n"), runs: false)
  renderer.update(long, turn: "a", streaming: false)
  #expect(renderer.height == renderer.cap && renderer.contentHeight > renderer.cap)
  // A short page shrinks; a streamed one only grows.
  renderer.update(Page(body: "Short", runs: false), turn: "b", streaming: true)
  let short = renderer.height
  renderer.update(Page(body: "Short\n\nLonger\n\nStill", runs: false), turn: "b", streaming: true)
  #expect(short == PaletteLayout.answerMin && renderer.height >= short)
  renderer.update(Page(body: "Short", runs: false), turn: "b", streaming: true)
  #expect(renderer.height >= short)
}

@MainActor @Test func aNativeClickNamesTheTargetAndItsRevision() {
  let renderer = NativePageRenderer()
  var clicks: [[String]] = []
  renderer.onTarget = { clicks.append([$0, $1]) }
  var page = Page(body: "<row title=\"One\" copy=\"1\"/>", runs: false)
  page.targetRevision = "r2"
  renderer.update(page, turn: "t", streaming: false)
  renderer.context.click("#0")
  #expect(clicks == [["#0", "r2"]])
}

/// A run of prose drawn as one text, as the page shows it.
@MainActor private func prose(_ body: String, streaming: Bool = false) -> NSAttributedString {
  let document = PageDocument(Page(body: body, runs: false), turn: "t", streaming: streaming)
  var builder = ProseBuilder(context: PageContext(), selection: nil, boxed: false, dark: false)
  builder.add(document.blocks, after: nil)
  return builder.text
}

@MainActor @Test func oneDragSelectsAcrossHeadingParagraphTableAndCode() {
  let body =
    "## Plan\nShip it.\n\n| Step | When |\n|---|---|\n| Build | Now |\n\n```sh\nswift build\n```\n\n<row title=\"Open\" open=\"https://apple.com\"/>\nAfter"
  let blocks = PageDocument(Page(body: body, runs: false), turn: "t", streaming: false).blocks
  // The heading, paragraph, table and code are one run; the row stands apart from the paragraph after it.
  #expect(PageBlocks.segments(blocks) == [0..<4, 4..<5, 5..<6])
  let view = ProseTextView()
  view.show(prose(body), code: [], accent: .blue)
  // What ⌘C copies: the pasteboard itself is out of reach headless.
  view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))
  let copied = view.attributedString().attributedSubstring(from: view.selectedRange()).string
  for part in ["Plan", "Ship it.", "Step", "Build", "Now", "swift build", "After"] {
    #expect(copied.contains(part))
  }
  #expect(!copied.contains("Open"))
}

@MainActor @Test func aStreamedRunReplacesOnlyItsEnd() {
  let view = ProseTextView()
  let first = prose("## Plan\nShip it.\n\nThen", streaming: true)
  let next = prose("## Plan\nShip it.\n\nThen test.\n\n- one", streaming: true)
  view.show(first, code: [], accent: .blue)
  view.show(next, code: [], accent: .blue)
  #expect(view.textStorage!.isEqual(to: next))
  let shorter = prose("Other")
  view.show(shorter, code: [], accent: .blue)
  #expect(view.textStorage!.isEqual(to: shorter))
}

@MainActor @Test func boxesThatLineUpAreMeasuredAtTheirOwnHeight() {
  let renderer = NativePageRenderer()
  // A card and a tile stretch to line up; measured with room to spare, they stay as tall as they are.
  let page = Page(
    body: "<columns>\n<tile label=\"Total\" title=\"42\"/>\n<card>\n## Notes\nOne line\n</card>\n</columns>",
    runs: false)
  renderer.update(page, turn: "t", streaming: false)
  #expect(renderer.contentHeight > 60 && renderer.contentHeight < 160)
}

@MainActor @Test func aSplitDetailIsMeasuredAtItsPaneWidth() {
  let renderer = NativePageRenderer()
  let page = Page(
    body: String(repeating: "A sentence that wraps sooner in a narrow pane. ", count: 8), runs: false)
  renderer.update(page, turn: "t", streaming: false)
  let wide = renderer.contentHeight
  let full = renderer.document
  renderer.update(page, turn: "t", width: PaletteLayout.splitDetail)
  #expect(renderer.document == full)
  #expect(renderer.context.width == PaletteLayout.splitDetail && renderer.contentHeight > wide * 1.4)
}

@MainActor @Test func proseKeepsItsLineHeightAndMarkers() {
  let text = prose("Body text\n\n- item\n\n```\ncode\n```")
  func style(_ fragment: String) -> NSParagraphStyle? {
    let location = (text.string as NSString).range(of: fragment).location
    return text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
  }
  // CSS line heights: 1.45 of the body size, and code keeps the body's line.
  #expect(style("Body")?.minimumLineHeight == 14 * 1.45 && style("Body")?.maximumLineHeight == 14 * 1.45)
  #expect(abs((style("code")?.minimumLineHeight ?? 0) - 14 * 1.45) < 0.01)
  // A list's disc is about 5 points across, ending 7 before the text at 20.
  let disc = (text.string as NSString).range(of: PageMetrics.disc).location
  let font = text.attribute(.font, at: disc, effectiveRange: nil) as? NSFont
  #expect(font.map { abs($0.pointSize - 14 * PageMetrics.discScale) < 0.01 } == true)
  #expect(style("item")?.tabStops.map(\.location) == [13, 20] && style("item")?.headIndent == 20)
}

@MainActor @Test func clickingProseLinksUsesThePanelsHandler() {
  var opened: [URL] = []
  let view = ProseTextView()
  view.open = { opened.append($0) }
  let address = URL(string: "wicket://weather?input=Berlin")!
  let external = URL(string: "https://example.com")!
  for url in [address, external, URL(fileURLWithPath: "/tmp/unsafe")] {
    view.clicked(onLink: url, at: 0)
  }
  #expect(opened == [address, external])
}

@MainActor @Test func codeSelectionChangesTheBlockAndLongLinesWrap() throws {
  let source = String(repeating: "a", count: 150)
  let blocks = document("```\n\(source)\n```").blocks
  func built(_ selection: String?) -> ProseBuilder {
    var builder = ProseBuilder(context: .init(), selection: selection, boxed: false, dark: false)
    builder.add(blocks, after: nil)
    return builder
  }
  let idle = built(nil)
  let chosen = built("#0")
  #expect(!idle.text.isEqual(to: chosen.text))
  #expect(chosen.text.string == source)
  let view = ProseTextView()
  view.show(chosen.text, code: chosen.code, accent: .blue)
  #expect(view.height(for: 140) > view.height(for: 600) * 2)
}

@MainActor @Test func keyboardSelectionRevealsACodeRangeBelowTheFold() async throws {
  _ = NSApplication.shared
  let renderer = NativePageRenderer()
  let paragraphs = (1...35).map { "Paragraph \($0)" }.joined(separator: "\n\n")
  let page = Page(body: paragraphs + "\n\n```\nCopy this command\n```", runs: false)
  renderer.update(page, turn: "code")
  let panel = PalettePanel()
  panel.setContentSize(NSSize(width: 640, height: 250))
  let host = NSHostingView(rootView: NativePageView(renderer: renderer).frame(width: 640, height: 250))
  panel.contentView = host
  defer { panel.contentView = nil }
  func prose(in view: NSView) -> ProseTextView? {
    (view as? ProseTextView) ?? view.subviews.lazy.compactMap { prose(in: $0) }.first
  }
  func codeIsVisible() -> Bool {
    host.layoutSubtreeIfNeeded()
    guard let view = prose(in: host), let layout = view.layoutManager, let container = view.textContainer
    else { return false }
    let range = (view.string as NSString).range(of: "Copy this command")
    guard range.location != NSNotFound else { return false }
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    return !rect.isEmpty && view.visibleRect.intersects(rect)
  }
  #expect(!codeIsVisible())
  renderer.selected = "#0"
  #expect(await eventually { codeIsVisible() })
  renderer.selected = nil
  renderer.update(Page(body: "Short detail", runs: false), turn: "detail")
  #expect(await eventually { !codeIsVisible() })
  renderer.update(page, turn: "code")
  #expect(await eventually { codeIsVisible() })
}

@MainActor @Test func secondaryInkResolvesToSolidTextInEitherAppearance() throws {
  func white(_ appearance: NSAppearance.Name) throws -> CGFloat {
    let appearance = try #require(NSAppearance(named: appearance))
    var color: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      color = Ink.secondaryColor.usingColorSpace(.sRGB)
    }
    let resolved = try #require(color)
    #expect(resolved.alphaComponent == 1)
    return resolved.redComponent
  }
  #expect(try white(.aqua) < 0.5)
  #expect(try white(.darkAqua) > 0.5)
}

@MainActor @Test func aProgressFromAnEmptyTotalStillDraws() {
  // A program dividing by an empty total sends `nan`; measuring the page draws its accessibility label.
  let renderer = NativePageRenderer()
  renderer.update(
    Page(body: "<progress label=\"Disk\" percent=\"nan\"/>", runs: false), turn: "a", streaming: false)
  #expect(renderer.height > 0)
}

@MainActor @Test func emptyTableCellsKeepTheirOwnLinesAndHeadingsTheirLevel() {
  let text = prose("## Plan\n\n| Step | When | Who |\n|---|---|---|\n| Build |  | Ana |")
  func blocks(at location: Int) -> [NSTextBlock] {
    (text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks
      ?? []
  }
  // Every line break belongs to the cell it ends, so the empty middle cell adds no line to "Build".
  let string = text.string as NSString
  var location = string.range(of: "Build").location
  var cells: [Int] = []
  while location < string.length {
    let line = string.lineRange(for: NSRange(location: location, length: 0))
    if let cell = blocks(at: line.location).last as? NSTextTableBlock { cells.append(cell.startingColumn) }
    location = NSMaxRange(line)
  }
  #expect(cells == [0, 1, 2])
  let heading = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
  #expect(heading?.headerLevel == 2)
}

@Test func shiftArrowsExtendAProseSelectionWithTheirKeypadFlags() throws {
  func arrow(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
  }
  // AppKit sends arrows with the numeric-pad and function flags set.
  #expect(PalettePanel.extendsSelection(try arrow(123, [.shift, .numericPad, .function])))
  #expect(PalettePanel.extendsSelection(try arrow(124, [.shift])))
  #expect(!PalettePanel.extendsSelection(try arrow(124, [.numericPad, .function])))
  #expect(!PalettePanel.extendsSelection(try arrow(124, [.shift, .command, .numericPad])))
}

@MainActor @Test func timelineUsesOrdinaryTargetsAndPlacesOverlapsToScale() throws {
  let page = Page(
    body: """
      <timeline lanes="Build,Ship" now="09:45" now-lane="Build">
      <span lane="Build" from="09:00" to="10:00" title="Compile" subtitle="Release" icon="hammer">
      <row label="Machine" value="Mac"/>
      </span>
      <span lane="Build" from="09:30" to="10:30" title="Test" open="https://example.com"/>
      <span lane="Build" from="10:30" to="11:00" title="Package"/>
      <span lane="Ship" from="11:30" to="12:00" title="Publish"/>
      </timeline>
      """, runs: false)
  let document = PageDocument(page, turn: "t", streaming: false)
  guard case .timeline(let timeline)? = document.blocks.first else {
    Issue.record("Expected a timeline")
    return
  }
  #expect(timeline.lanes == ["Build", "Ship"])
  #expect(timeline.range == 480...720)
  #expect(timeline.ticks == [480, 540, 600, 660, 720])
  #expect(timeline.marker == Timeline.Marker(value: 585, lane: 0))
  #expect(timeline.spans.map(\.column) == [0, 1, 0, 0])
  #expect(timeline.spans.map(\.columns) == [2, 2, 1, 1])
  #expect(timeline.spans.first?.item.icon == "hammer")
  #expect(timeline.fraction(600) == 0.5)
  #expect(page.targets.map(\.title) == ["Compile", "Test"])
  #expect(document.blocks[0].holds(page.targets[0].id))
  #expect(page.targets[1].actions.first?.kind == .open(URL(string: "https://example.com")!))
  if case .detail(let details, _)? = page.targets[0].actions.first?.kind {
    #expect(details.contains("Machine"))
  } else {
    Issue.record("Compile should open its detail")
  }
}

@MainActor @Test func timelinesAcceptNumericPositionsAndFallBackToRows() throws {
  let numeric = document(
    """
    <timeline lanes="Batch" from="0" to="10">
    <span lane="Batch" from="-2" to="2" title="Prepare"/>
    <span lane="Batch" from="3" to="7" title="Process" copy="processed"/>
    </timeline>
    """)
  guard case .timeline(let timeline)? = numeric.blocks.first else {
    Issue.record("Expected a timeline")
    return
  }
  #expect(!timeline.clock && timeline.ticks == [0, 2, 4, 6, 8, 10])
  #expect(timeline.spans[0].from == 0 && timeline.spans[0].to == 2)

  let invalid = Page(
    body: """
      <timeline lanes="Batch">
      <span lane="Missing" from="2" to="4" title="Still readable" copy="x"/>
      </timeline>
      """, runs: false)
  let blocks = PageDocument(invalid, turn: "t", streaming: false).blocks
  #expect(kinds(blocks) == ["rows1"])
  #expect(blocks.first?.holds(invalid.targets[0].id) == true)
  #expect(kinds(document("`<timeline lanes='X'><span lane='X'/></timeline>`").blocks) == ["p"])
}

@MainActor @Test func tileColumnsWrapAfterSevenEvenWithRoomForMore() {
  let renderer = NativePageRenderer()
  func height(_ count: Int) -> CGFloat {
    let tiles = (1...count).map { #"<tile title="\#($0)" subtitle="Event"/>"# }
    let page = Page(body: (["<columns>"] + tiles + ["</columns>"]).joined(separator: "\n"), runs: false)
    renderer.update(page, turn: "grid", width: 1000)
    return renderer.contentHeight
  }
  let firstRow = height(7)
  let secondRow = height(8)
  #expect(secondRow > firstRow + 30)
  #expect(height(14) == secondRow)
  #expect(height(15) > secondRow + 30)
}
