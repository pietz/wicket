import AppKit
import SwiftUI

/// A run of prose (headings, paragraphs, lists, quotes, rules, tables and code) as one read-only text
/// view, so a drag selects across its blocks and ⌘C copies them, as in any Mac text. Components (rows,
/// tiles, cards, charts, fields) stay SwiftUI between runs. TextKit 1: tables are `NSTextTable`, which
/// TextKit 2 would fall back from anyway.
struct PageProse: NSViewRepresentable {
  let blocks: [PageBlock]
  let boxed: Bool
  var tight = false
  /// The block before the run, which sets the run's first gap and greys a headline's context line.
  let previous: PageBlock?
  @Environment(\.page) private var context
  @Environment(\.pageSelection) private var selection
  @Environment(\.colorScheme) private var scheme

  func makeNSView(context: Context) -> ProseTextView { ProseTextView() }

  func updateNSView(_ view: ProseTextView, context _: Context) {
    view.click = context.click
    view.open = context.open
    view.configure(
      .init(
        blocks: blocks, previous: previous, context: context, selection: selection, boxed: boxed,
        tight: tight, dark: scheme == .dark))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context _: Context) -> CGSize? {
    let width = proposal.width ?? self.context.width - 40
    return CGSize(width: width, height: view.height(for: width))
  }
}

/// The prose's text view: selectable, not editable, drawing nothing behind its text, with a copy
/// button on each code block that copies.
/// Inline code and badges sit on rounded chips, as on the web; TextKit fills their background square.
private final class ProseLayoutManager: NSLayoutManager {
  override func fillBackgroundRectArray(
    _ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange range: NSRange, color: NSColor
  ) {
    // The selection fills through here too, and stays square.
    guard let storage = textStorage, range.location < storage.length,
      storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor == color
    else { return super.fillBackgroundRectArray(rects, count: count, forCharacterRange: range, color: color) }
    for index in 0..<count {
      let rect = rects[index].insetBy(dx: -2, dy: 1)
      NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }
  }
}

final class ProseTextView: NSTextView {
  struct Input: Equatable {
    let blocks: [PageBlock]
    let previous: PageBlock?
    let context: PageContext
    let selection: String?
    let boxed: Bool
    let tight: Bool
    let dark: Bool
  }
  var click: @MainActor (String) -> Void = { _ in }
  var open: @MainActor (URL) -> Void = { _ in }
  private var input: Input?
  private var fittedWidth: CGFloat?
  private var pendingScroll: String?

  func configure(_ input: Input) {
    guard input != self.input else { return }
    if input.selection != self.input?.selection { pendingScroll = input.selection }
    self.input = input
    fittedWidth = nil
    needsLayout = true
  }

  private func fit(_ width: CGFloat) {
    guard let input, fittedWidth != width else { return }
    fittedWidth = width
    var builder = ProseBuilder(
      context: input.context, selection: input.selection, boxed: input.boxed, dark: input.dark,
      tight: input.tight, width: width)
    builder.add(input.blocks, after: input.previous)
    show(builder.text, code: builder.code, accent: .controlAccentColor)
  }

  override func clicked(onLink link: Any, at charIndex: Int) {
    if let url = link as? URL, AnswerLink.allowed(url) { open(url) }
  }

  private var code: [(range: NSRange, id: String)] = []
  private var buttons: [NSButton] = []

  init() {
    let storage = NSTextStorage()
    let layout = ProseLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    drawsBackground = false
    isRichText = true
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }
  override init(frame: NSRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
  }

  func show(_ text: NSAttributedString, code: [(range: NSRange, id: String)], accent: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
      .foregroundColor: accent, .cursor: NSCursor.pointingHand,
    ]
    if !NSDictionary(dictionary: linkTextAttributes ?? [:]).isEqual(to: attributes) {
      linkTextAttributes = attributes
    }
    if let storage = textStorage, !storage.isEqual(to: text) {
      replace(storage, with: text)
      needsLayout = true
    }
    guard code.map(\.id) != self.code.map(\.id) || code.map(\.range) != self.code.map(\.range) else { return }
    self.code = code
    for button in buttons { button.removeFromSuperview() }
    buttons = code.map { block in
      let button = NSButton(
        image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")!, target: self,
        action: #selector(copyCode(_:)))
      button.isBordered = false
      button.contentTintColor = Ink.secondaryColor
      button.toolTip = "Copy code"
      button.identifier = NSUserInterfaceItemIdentifier(block.id)
      addSubview(button)
      return button
    }
    needsLayout = true
  }

  /// A streamed run changes at its end: only the paragraphs from the first change on are replaced, so
  /// TextKit lays out only those again.
  private func replace(_ storage: NSTextStorage, with text: NSAttributedString) {
    let old = storage.string as NSString
    let new = text.string as NSString
    var same = 0
    let length = min(old.length, new.length)
    while same < length, old.character(at: same) == new.character(at: same) { same += 1 }
    let start = new.paragraphRange(for: NSRange(location: min(same, max(0, new.length - 1)), length: 0))
      .location
    let kept = NSRange(location: 0, length: min(start, old.length))
    guard start > 0, storage.attributedSubstring(from: kept).isEqual(to: text.attributedSubstring(from: kept))
    else { return storage.setAttributedString(text) }
    storage.replaceCharacters(
      in: NSRange(location: start, length: old.length - start),
      with: text.attributedSubstring(from: NSRange(location: start, length: new.length - start)))
  }

  @objc private func copyCode(_ sender: NSButton) {
    if let id = sender.identifier?.rawValue { click(id) }
  }

  func height(for width: CGFloat) -> CGFloat {
    fit(width)
    guard let container = textContainer, let layout = layoutManager else { return 0 }
    if container.size.width != width {
      container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    layout.ensureLayout(for: container)
    placeButtons()
    return ceil(layout.usedRect(for: container).height)
  }

  override func layout() {
    super.layout()
    guard bounds.width > 0 else { return }
    fit(bounds.width)
    placeButtons()
    if let id = pendingScroll, let range = code.first(where: { $0.id == id })?.range {
      pendingScroll = nil
      scrollRangeToVisible(range)
    }
  }

  /// Each copy button in its code block's top right corner.
  private func placeButtons() {
    guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
    for (block, button) in zip(code, buttons) where NSMaxRange(block.range) <= storage.length {
      guard
        let box =
          (storage.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil)
          as? NSParagraphStyle)?.textBlocks.last
      else { continue }
      // The block spans the run's width; its text starts its top padding below the block's top.
      let glyphs = layout.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
      let text = layout.boundingRect(forGlyphRange: glyphs, in: container)
      let top = text.minY - box.width(for: .padding, edge: .minY) - box.width(for: .border, edge: .minY)
      button.frame = NSRect(x: container.size.width - 33, y: top + 5, width: 28, height: 28)
    }
  }

  // The panel's input takes back typing (`PalettePanel.route`); this view keeps only what selects and copies.
  override var acceptsFirstResponder: Bool { true }
}

/// A box with rounded corners: a code block's, filled and edged as `PageBox` draws one, and filled as a
/// selected row is when its copy target is selected.
private final class RoundedBlock: NSTextBlock {
  let selected: Bool
  let radius: CGFloat
  private let spacing: CGFloat
  private let hasTarget: Bool

  init(selected: Bool, radius: CGFloat, spacing: CGFloat, scale: CGFloat, hasTarget: Bool) {
    self.selected = selected
    self.radius = radius
    self.spacing = spacing
    self.hasTarget = hasTarget
    super.init()
    setContentWidth(100, type: .percentageValueType)
    setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .minY)
    setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: .maxY)
    setWidth(14 * scale, type: .absoluteValueType, for: .padding, edge: .minX)
    setWidth((hasTarget ? 44 : 14) * scale, type: .absoluteValueType, for: .padding, edge: .maxX)
    setWidth(spacing, type: .absoluteValueType, for: .margin, edge: .minY)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? RoundedBlock else { return false }
    return selected == other.selected && radius == other.radius && spacing == other.spacing
      && hasTarget == other.hasTarget
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(selected)
    hasher.combine(radius)
    hasher.combine(spacing)
    hasher.combine(hasTarget)
    return hasher.finalize()
  }

  override func drawBackground(
    withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
    layoutManager: NSLayoutManager
  ) {
    let rect = NSRect(
      x: frameRect.minX + width(for: .margin, edge: .minX),
      y: frameRect.minY + width(for: .margin, edge: .minY),
      width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
      height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY))
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
    (selected ? Ink.selectionColor : Ink.surfaceColor).setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }
}

/// Builds the attributed text of a run of prose, with the page's rhythm as paragraph spacing.
@MainActor struct ProseBuilder {
  let context: PageContext
  let selection: String?
  let boxed: Bool
  let dark: Bool
  let tight: Bool
  let width: CGFloat
  private(set) var text = NSMutableAttributedString()
  private(set) var code: [(range: NSRange, id: String)] = []

  init(
    context: PageContext, selection: String?, boxed: Bool, dark: Bool, tight: Bool = false,
    width: CGFloat? = nil
  ) {
    self.context = context
    self.selection = selection
    self.boxed = boxed
    self.dark = dark
    self.tight = tight
    self.width = width ?? context.width - 40
  }

  private let ink = Ink.primaryColor
  private let muted = Ink.secondaryColor
  private let line = NSColor.separatorColor
  private func font(_ points: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: context.size(points), weight: weight)
  }

  /// One paragraph's layout: the gap before it, its indents and the boxes it stands in.
  private func style(
    before: CGFloat, indent: CGFloat = 0, hanging: CGFloat = 0, blocks: [NSTextBlock] = [],
    alignment: NSTextAlignment = .natural, wrap: NSLineBreakMode = .byWordWrapping
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacingBefore = context.size(before)
    style.firstLineHeadIndent = indent
    style.headIndent = indent + hanging
    // A list's marker ends 7 points before its text, before its text.
    style.tabStops =
      hanging > 0
      ? [
        NSTextTab(textAlignment: .right, location: indent + hanging - context.size(7)),
        NSTextTab(textAlignment: .natural, location: indent + hanging),
      ] : []
    style.textBlocks = blocks
    style.alignment = alignment
    style.lineBreakMode = wrap
    return style
  }

  /// TextKit ignores a plain block without a content width once its
  /// paragraphs have line or paragraph spacing.
  private static func block() -> NSTextBlock {
    let block = NSTextBlock()
    block.setContentWidth(100, type: .percentageValueType)
    return block
  }

  mutating func add(_ blocks: [PageBlock], after previous: PageBlock?) {
    var previous = previous
    for block in blocks {
      let before = previous.map { PageBlocks.gap($0, block, boxed: boxed, tight: tight) } ?? 0
      add(block, before: text.length == 0 ? 0 : before, after: previous, indent: 0, boxes: [])
      previous = block
    }
  }

  /// Appends a paragraph. `lines` sets its line height to a multiple of the font size with the
  /// extra split above and below the text; TextKit would put it all above.
  private mutating func paragraph(
    _ string: NSAttributedString, _ style: NSParagraphStyle, lines: (font: NSFont, ratio: CGFloat)? = nil
  ) {
    // The line break ends the paragraph before, so it carries that paragraph's font and layout; text
    // without them would be filled in by the text view and never compare equal on the next update.
    if text.length > 0 {
      var attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
      attributes[.link] = nil
      attributes[.backgroundColor] = nil
      text.append(NSAttributedString(string: "\n", attributes: attributes))
    }
    let start = text.length
    text.append(string)
    let range = NSRange(location: start, length: text.length - start)
    guard let lines else { return text.addAttribute(.paragraphStyle, value: style, range: range) }
    let height = lines.font.pointSize * lines.ratio
    let fixed = style.mutableCopy() as! NSMutableParagraphStyle
    fixed.minimumLineHeight = height
    fixed.maximumLineHeight = height
    text.addAttribute(.paragraphStyle, value: fixed, range: range)
    let rise = (height - (lines.font.ascender - lines.font.descender + lines.font.leading)) / 2
    text.enumerateAttribute(.baselineOffset, in: range) { value, run, _ in
      text.addAttribute(.baselineOffset, value: ((value as? CGFloat) ?? 0) + rise, range: run)
    }
  }

  private mutating func add(
    _ block: PageBlock, before: CGFloat, after previous: PageBlock?, indent: CGFloat, boxes: [NSTextBlock],
    marker: String? = nil
  ) {
    let hanging: CGFloat = marker == nil ? 0 : context.size(PageMetrics.indent)
    func lead(_ string: NSAttributedString, _ font: NSFont) -> NSAttributedString {
      guard let marker else { return string }
      let result = NSMutableAttributedString(string: "\t", attributes: [.font: font])
      if marker == PageMetrics.disc {
        result.append(
          NSAttributedString(
            string: marker,
            attributes: [
              .font: NSFont.systemFont(ofSize: font.pointSize * PageMetrics.discScale),
              .baselineOffset: font.pointSize * PageMetrics.discRise, .foregroundColor: muted,
            ]))
      } else {
        result.append(NSAttributedString(string: marker, attributes: [.font: font, .foregroundColor: muted]))
      }
      result.append(NSAttributedString(string: "\t", attributes: [.font: font]))
      result.append(string)
      return result
    }
    switch block {
    case .heading(let level, let inline):
      let size =
        boxed && previous == nil
        ? PageMetrics.titleSize
        : level == 1 ? PageMetrics.headlineSize : level == 2 ? PageMetrics.titleSize : PageMetrics.bodySize
      let font = font(size, .semibold)
      // VoiceOver's heading navigation reads the level; size alone doesn't make a heading.
      let heading =
        style(before: before, indent: indent, hanging: hanging, blocks: boxes)
        .mutableCopy() as! NSMutableParagraphStyle
      heading.headerLevel = level
      paragraph(
        lead(attributed(inline, font: font, color: ink), font), heading,
        lines: (font, size == PageMetrics.headlineSize ? PageMetrics.headline : PageMetrics.heading))
    case .paragraph(let inline):
      let grey = !boxed && { if case .heading(1, _) = previous { true } else { false } }() || !boxes.isEmpty
      let font = font(PageMetrics.bodySize)
      paragraph(
        lead(attributed(inline, font: font, color: grey ? muted : ink), font),
        style(before: before, indent: indent, hanging: hanging, blocks: boxes),
        lines: (font, PageMetrics.body))
    case .list(let ordered, let start, let items):
      for (index, item) in items.enumerated() {
        var inner: PageBlock?
        for (position, child) in item.enumerated() {
          let gap = index == 0 && position == 0 ? before : 4
          add(
            child, before: gap, after: inner,
            indent: position == 0 ? indent : indent + context.size(PageMetrics.indent), boxes: boxes,
            marker: position == 0 ? (ordered ? "\(start + index)." : PageMetrics.disc) : nil)
          inner = child
        }
      }
    case .quote(let children):
      let quote = Self.block()
      quote.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
      quote.setBorderColor(line, for: .minX)
      quote.setWidth(context.size(10), type: .absoluteValueType, for: .padding, edge: .minX)
      // The gap above is the block's margin, so the bar spans only the quote.
      quote.setWidth(context.size(before), type: .absoluteValueType, for: .margin, edge: .minY)
      var inner: PageBlock?
      for (position, child) in children.enumerated() {
        add(child, before: position == 0 ? 0 : 8, after: inner, indent: indent, boxes: boxes + [quote])
        inner = child
      }
    case .rule:
      let rule = Self.block()
      rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
      rule.setBorderColor(line, for: .maxY)
      paragraph(
        NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)]),
        style(before: before, blocks: boxes + [rule]))
    case .table(let table):
      let grid = NSTextTable()
      grid.numberOfColumns = max(1, table.alignments.count)
      grid.collapsesBorders = true
      grid.layoutAlgorithm = .automaticLayoutAlgorithm
      let rows = (table.header.isEmpty ? [] : [table.header]) + table.rows
      // As wide as its content, up to the proposed width.
      let gutter = context.size(24)
      var widths = [CGFloat](repeating: 0, count: grid.numberOfColumns)
      for (row, cells) in rows.enumerated() {
        let header = row == 0 && !table.header.isEmpty
        let font = header ? font(PageMetrics.smallSize, .medium) : font(PageMetrics.bodySize)
        for (column, cell) in cells.enumerated() where column < widths.count {
          widths[column] = max(
            widths[column], ceil(attributed(cell, font: font, color: ink).size().width) + 1)
        }
      }
      let natural = widths.reduce(0, +) + gutter * CGFloat(max(0, widths.count - 1))
      let fits = natural <= width - indent
      if !fits { grid.setContentWidth(100, type: .percentageValueType) }
      for (row, cells) in rows.enumerated() {
        for (column, cell) in cells.enumerated() {
          let box = NSTextTableBlock(
            table: grid, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
          if fits, column < widths.count {
            box.setContentWidth(widths[column], type: .absoluteValueType)
          }
          // The first row under a header has more room above it.
          box.setWidth(
            context.size(row == 1 && !table.header.isEmpty ? 8 : 4), type: .absoluteValueType, for: .padding,
            edge: .minY)
          box.setWidth(
            context.size(row == 0 && !table.header.isEmpty ? 6 : 4), type: .absoluteValueType, for: .padding,
            edge: .maxY)
          box.setWidth(
            column == 0 ? 0 : gutter, type: .absoluteValueType, for: .padding, edge: .minX)
          if row == 0, !table.header.isEmpty {
            box.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            box.setBorderColor(line, for: .maxY)
          }
          let header = row == 0 && !table.header.isEmpty
          let font = header ? font(PageMetrics.smallSize, .medium) : font(PageMetrics.bodySize)
          let alignment: NSTextAlignment =
            switch column < table.alignments.count ? table.alignments[column] : .leading {
            case .leading: .natural
            case .center: .center
            case .trailing: .right
            }
          // An empty cell still needs a character to carry its block, or the line break before the
          // next cell would add a blank line to the previous one.
          let content = attributed(cell, font: font, color: header ? muted : ink)
          paragraph(
            content.length > 0 ? content : NSAttributedString(string: " ", attributes: [.font: font]),
            style(
              before: row == 0 ? before : 0, indent: indent, blocks: boxes + [box],
              alignment: alignment), lines: (font, PageMetrics.body))
        }
      }
    case .code(let source, let target):
      let box = RoundedBlock(
        selected: target != nil && target == selection, radius: context.size(PageMetrics.cornerRadius),
        spacing: context.size(before), scale: context.scale, hasTarget: target != nil)
      let start = text.length + (text.length > 0 ? 1 : 0)
      let font = NSFont.monospacedSystemFont(
        ofSize: context.size(PageMetrics.bodySize * 0.9), weight: .regular)
      let code = NSAttributedString(
        string: source.isEmpty ? " " : source, attributes: [.font: font, .foregroundColor: ink])
      paragraph(
        code, style(before: 0, indent: indent, blocks: boxes + [box], wrap: .byCharWrapping),
        lines: (font, PageMetrics.code))
      if let target { self.code.append((NSRange(location: start, length: text.length - start), target)) }
    default:
      break
    }
  }

  /// Inline text with its styles: strong, emphasis, code, links and badges.
  private func attributed(_ inline: PageInline, font: NSFont, color: NSColor) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for run in inline.runs {
      switch run {
      case .text(let text):
        for piece in text.runs {
          var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
          let intent = piece.inlinePresentationIntent ?? []
          var styled = font
          if intent.contains(.stronglyEmphasized) {
            styled = .systemFont(ofSize: font.pointSize, weight: .semibold)
          }
          if intent.contains(.emphasized) {
            styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
          }
          if intent.contains(.code) {
            styled = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            attributes[.backgroundColor] = (dark ? NSColor.white : .black).withAlphaComponent(
              dark ? 0.12 : 0.07)
          }
          attributes[.font] = styled
          if let link = piece.link { attributes[.link] = link }
          result.append(
            NSAttributedString(string: String(text[piece.range].characters), attributes: attributes))
        }
      case .badge(let item):
        let tone = Ink.tone(item.tone).map { NSColor($0) }
        let small = NSFont.systemFont(ofSize: context.size(PageMetrics.smallSize), weight: .medium)
        if item.tone == "warning", let tone {
          result.append(
            NSAttributedString(
              string: "● ",
              attributes: [.font: NSFont.systemFont(ofSize: context.size(8)), .foregroundColor: tone]))
        }
        let filled = item.tone != "warning" ? tone : nil
        result.append(
          NSAttributedString(
            string: "\u{2009}\(item.label ?? "")\u{2009}",
            attributes: [
              .font: small, .foregroundColor: filled == nil ? muted : ink,
              .backgroundColor: filled?.withAlphaComponent(0.16)
                ?? (dark ? NSColor.white : .black).withAlphaComponent(0.08),
            ]))
      }
    }
    return result
  }
}

extension PageBlock {
  /// Text that a run of prose draws, so a selection can span it. A list or quote holding a component
  /// is not.
  var isProse: Bool {
    switch self {
    case .heading, .paragraph, .rule, .table, .code: true
    case .list(_, _, let items): items.allSatisfy { $0.allSatisfy(\.isProse) }
    case .quote(let blocks): blocks.allSatisfy(\.isProse)
    default: false
    }
  }
}
