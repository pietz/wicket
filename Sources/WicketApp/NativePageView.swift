import AppKit
import ImageIO
import SwiftUI

/// Layout and callbacks for the page revision a block is drawn from.
struct PageContext: Equatable, Sendable {
  var scale: CGFloat = 1
  var rowHeight: CGFloat = 40
  /// The page's width: the card's, or a split list's detail pane.
  var width = PaletteLayout.pageWidth
  var revision = ""
  var turn = ""
  var focusedField: String?
  enum TextEvent {
    case focus
    case edit(String)
    case blur
  }
  var text: @MainActor (String, TextEvent) -> Void = { _, _ in }
  var open: @MainActor (URL) -> Void = { _ in }
  var click: @MainActor (String) -> Void = { _ in }
  var change: @MainActor (Page.Control.Change) -> Void = { _ in }
  /// A field was used: the keyboard goes back to the input.
  var release: @MainActor () -> Void = {}

  static func == (a: Self, b: Self) -> Bool {
    a.scale == b.scale && a.rowHeight == b.rowHeight && a.width == b.width
      && a.revision == b.revision && a.turn == b.turn && a.focusedField == b.focusedField
  }

  func size(_ points: CGFloat) -> CGFloat { points * scale }
  var body: Font { .system(size: size(PageMetrics.bodySize)) }
  var small: Font { .system(size: size(PageMetrics.smallSize)) }
}

private enum PageContextKey: EnvironmentKey { static let defaultValue = PageContext() }
private enum PageSelectionKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
  var page: PageContext {
    get { self[PageContextKey.self] }
    set { self[PageContextKey.self] = newValue }
  }
  /// Separate from the context so only blocks with targets read it.
  var pageSelection: String? {
    get { self[PageSelectionKey.self] }
    set { self[PageSelectionKey.self] = newValue }
  }
}

/// The page's blocks at the panel's width, with no scroll view: what is shown and what is measured.
struct PageBody: View {
  let document: PageDocument
  /// Shown in a scroll view, blocks lay out as they come into view, so a long page or stream costs what
  /// is visible; measured, all of them.
  var lazy = false
  @Environment(\.page) private var context

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let picture = document.picture {
        PagePicture(url: picture, spacing: context.size(16), loadsImage: lazy)
      }
      // Keep the field editor mounted when the scroll view moves it out of view.
      PageBlocks(blocks: document.blocks, lazy: lazy && !document.hasTextFields)
    }
    .font(context.body)
    .lineHeight(PageMetrics.lineHeight(PageMetrics.body))
    .foregroundStyle(Ink.primary)
    .padding(.horizontal, 20)
    .padding(.top, context.size(12))
    .padding(.bottom, context.size(16))
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

/// A list of blocks with the page's rhythm: blocks 16 apart, 8 inside a box, a heading closer to what it
/// heads and further from what came before it.
struct PageBlocks: View {
  let blocks: [PageBlock]
  var boxed = false
  var tight = false
  var lazy = false
  @Environment(\.page) private var context

  var body: some View {
    if lazy {
      LazyVStack(alignment: .leading, spacing: 0) { items }
    } else {
      VStack(alignment: .leading, spacing: 0) { items }
    }
  }

  private var items: some View {
    let segments = Self.segments(blocks).map { range in
      (id: Self.id(range.lowerBound, in: blocks, lazy: lazy), range: range)
    }
    return ForEach(segments, id: \.id) { segment in
      let range = segment.range
      let index = range.lowerBound
      let previous = index > 0 ? blocks[index - 1] : nil
      SwiftUI.Group {
        if blocks[index].isProse {
          PageProse(blocks: Array(blocks[range]), boxed: boxed, tight: tight, previous: previous)
        } else {
          PageBlockView(block: blocks[index])
        }
      }
      .padding(
        .top,
        previous.map { context.size(Self.gap($0, blocks[index], boxed: boxed, tight: tight)) } ?? 0
      )
      .id(segment.id)
    }
  }

  /// The blocks as shown: each run of prose together, each other block alone.
  static func segments(_ blocks: [PageBlock]) -> [Range<Int>] {
    var segments: [Range<Int>] = []
    for index in blocks.indices {
      if blocks[index].isProse, let last = segments.last, last.upperBound == index,
        blocks[last.lowerBound].isProse
      {
        segments[segments.count - 1] = last.lowerBound..<index + 1
      } else {
        segments.append(index..<index + 1)
      }
    }
    return segments
  }

  /// A block's scroll id: the page's own blocks are named apart from those nested in lists and boxes.
  static func id(_ index: Int, in blocks: [PageBlock], lazy: Bool) -> String {
    if !lazy, let field = blocks[index].firstTextField { return "field-block-\(field)" }
    return lazy ? "page-block-\(index)" : "block-\(index)"
  }

  static func gap(_ previous: PageBlock, _ block: PageBlock, boxed: Bool, tight: Bool) -> CGFloat {
    if tight { return 4 }
    let base: CGFloat = boxed ? 8 : 16
    if case .heading(let level, _) = previous {
      return boxed ? 4 : level == 1 ? 4 : 8
    }
    if case .heading = block { return base + 8 }
    if case .card = previous, case .card = block { return 8 }
    return base
  }
}

private struct PageBlockView: View {
  let block: PageBlock
  @Environment(\.page) private var context

  var body: some View {
    switch block {
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: context.size(4)) {
        ForEach(items.indices, id: \.self) { index in
          HStack(alignment: .firstTextBaseline, spacing: context.size(7)) {
            Group {
              if ordered {
                Text("\(start + index).").monospacedDigit()
              } else {
                Text(PageMetrics.disc).font(
                  .system(size: context.size(PageMetrics.bodySize) * PageMetrics.discScale)
                )
                .baselineOffset(context.size(PageMetrics.bodySize) * PageMetrics.discRise)
              }
            }
            .foregroundStyle(Ink.secondary)
            .frame(width: context.size(PageMetrics.indent - 7), alignment: .trailing)
            PageBlocks(blocks: items[index], tight: true)
          }
        }
      }
    case .quote(let blocks):
      PageBlocks(blocks: blocks, boxed: true).foregroundStyle(Ink.secondary)
        .padding(.leading, context.size(12))
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
    case .heading, .paragraph, .rule, .table, .code:
      PageProse(blocks: [block], boxed: true, previous: nil)
    case .rows(let items): PageRows(items: items)
    case .properties(let items): PageProperties(items: items)
    case .tile(let item): PageTile(item: item)
    case .progresses(let items): PageProgresses(items: items)
    case .badges(let items):
      PageFlow(spacing: 6) { ForEach(items.indices, id: \.self) { PageBadge(item: items[$0]) } }
    case .card(let icon, let blocks): PageCard(icon: icon, blocks: blocks)
    case .columns(let blocks):
      let wide = blocks.contains { if case .tile = $0 { false } else { true } }
      PageColumns(minimum: wide ? 200 : 72, spacing: context.size(8)) {
        ForEach(blocks.indices, id: \.self) {
          PageBlocks(blocks: [blocks[$0]], boxed: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    case .fields(let controls): PageFields(controls: controls)
    case .chart(let chart, let pending): NativeChart(chart: chart, pending: pending)
    }
  }
}

/// Page typography before the user's text-size scaling.
enum PageMetrics {
  static let smallSize: CGFloat = 12
  static let bodySize: CGFloat = 14
  static let titleSize: CGFloat = 16
  static let figureSize: CGFloat = 20
  static let headlineSize: CGFloat = 24
  static let cornerRadius: CGFloat = 12
  static let chartHeight: CGFloat = 202
  /// Code uses a smaller monospace font while keeping the body's line height.
  static let body: CGFloat = 1.45
  static let headline: CGFloat = 1.2
  static let heading: CGFloat = 1.3
  static let code: CGFloat = body / 0.9
  static func lineHeight(_ ratio: CGFloat) -> AttributedString.LineHeight { .multiple(factor: ratio) }
  /// A disc larger than the bullet glyph, centred on lowercase letters.
  static let indent: CGFloat = 20
  static let disc = "\u{25CF}"
  static let discScale: CGFloat = 0.44
  static let discRise: CGFloat = 0.11
}

/// A capsule, tinted in its tone. Amber is never a fill: a warning is a dot.
private struct PageBadge: View {
  let item: PageItem
  @Environment(\.page) private var context

  var body: some View {
    let tone = Ink.tone(item.tone)
    HStack(spacing: 5) {
      if item.tone == "warning", let tone { Circle().fill(tone).frame(width: 6, height: 6) }
      Text(item.label ?? "")
    }
    .font(.system(size: context.size(PageMetrics.smallSize), weight: .medium))
    .foregroundStyle(tone != nil && item.tone != "warning" ? Ink.primary : Ink.secondary)
    .padding(.horizontal, 8).padding(.vertical, 2)
    .background(
      (item.tone == "warning" ? nil : tone)?.opacity(0.16) ?? Color.primary.opacity(0.08), in: .capsule)
  }
}

/// A box: a tile's, a card's, a code block's. Selected, it is filled exactly as a selected row is, so
/// one selection reads the same on every part of the panel; its edge stays, so the box keeps its shape.
private struct PageBox: ViewModifier {
  let selected: Bool
  @Environment(\.page) private var context

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: context.size(PageMetrics.cornerRadius), style: .continuous)
    content
      .background(selected ? Ink.selection : Ink.surface, in: shape)
      .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
  }
}

/// An item's icon in the native row's 26-point frame: an extension's image, a file's own icon, or a
/// symbol in grey.
private struct PageIcon: View {
  let item: PageItem
  var size: CGFloat = 26
  @Environment(\.page) private var context

  var body: some View {
    Group {
      if let image = item.image {
        RowImage(version: image, fallback: item.icon ?? "app", symbolSize: size * 20 / 26)
      } else if let file = item.file {
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
      } else if let icon = item.icon {
        Image(systemName: icon).font(.system(size: size * 20 / 26)).foregroundStyle(Ink.secondary)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Rows as the launcher's own list draws them: its height and spacing, icon, title, grey subtitle and
/// value, and its selection. A row with a target is a button.
private struct PageRows: View {
  let items: [PageItem]
  @Environment(\.page) private var context
  @Environment(\.pageSelection) private var selection

  var body: some View {
    let icons = items.contains { $0.icon != nil || $0.file != nil || $0.image != nil }
    VStack(spacing: 2) {
      ForEach(items.indices, id: \.self) { index in
        let item = items[index]
        let selected = item.target != nil && item.target == selection
        HStack(spacing: 10) {
          if icons && item.label == nil { PageIcon(item: item) }
          if let label = item.label {
            // As wide as a time at least, so titles after short labels line up.
            Text(label).foregroundStyle(Ink.secondary).lineLimit(1)
              .frame(minWidth: context.size(PageMetrics.bodySize) * 3.4, alignment: .leading)
          }
          if let title = item.title {
            Text(title).lineLimit(1).layoutPriority(1)
              .foregroundStyle(item.tone == ActionTone.destructive.rawValue ? Ink.destructive : Ink.primary)
          }
          if let subtitle = item.subtitle { Text(subtitle).foregroundStyle(Ink.secondary).lineLimit(1) }
          Spacer(minLength: 8)
          if let value = item.value { Text(value).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize() }
        }
        .font(.system(size: 14 * context.scale))
        .padding(.horizontal, 10)
        .frame(minHeight: context.rowHeight)
        .background {
          if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.selection) }
        }
        .contentShape(.rect)
        .onTapGesture { if let target = item.target { context.click(target) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.target == nil ? [] : selected ? [.isButton, .isSelected] : .isButton)
        .id(item.target)
      }
    }
    .padding(.horizontal, -10)
  }
}

/// Labels and values, as in a form: the labels share a column and the values wrap.
private struct PageProperties: View {
  let items: [PageItem]
  @Environment(\.page) private var context

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: context.size(12)) {
      ForEach(items.indices, id: \.self) { index in
        GridRow {
          Text(items[index].label ?? "").foregroundStyle(Ink.secondary)
          Text(items[index].value ?? items[index].subtitle ?? "").textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, context.size(2))
  }
}

/// A boxed item, laid out by its own width: wide, the grey label on top, the title large with the value
/// at the end of its line and the symbol in the top right corner; narrow (four or more across), centred,
/// as the days of a forecast.
private struct PageTile: View {
  let item: PageItem
  @Environment(\.page) private var context
  @Environment(\.pageSelection) private var selection

  var body: some View {
    let selected = item.target != nil && item.target == selection
    ViewThatFits(in: .horizontal) {
      wide.frame(
        minWidth: 150, idealWidth: 150, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      narrow.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .modifier(PageBox(selected: selected))
    .contentShape(.rect)
    .onTapGesture { if let target = item.target { context.click(target) } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(item.target == nil ? [] : selected ? [.isButton, .isSelected] : .isButton)
    .id(item.target)
  }

  private var wide: some View {
    VStack(alignment: .leading, spacing: context.size(4)) {
      if let label = item.label {
        Text(label).font(.system(size: context.size(PageMetrics.smallSize), weight: .medium)).foregroundStyle(
          Ink.secondary
        )
        .padding(.trailing, item.icon == nil ? 0 : 28)
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let title = item.title {
          Text(title).font(.system(size: context.size(PageMetrics.figureSize), weight: .semibold))
            .lineHeight(PageMetrics.lineHeight(PageMetrics.headline))
            .padding(.trailing, item.icon != nil && item.label == nil ? 28 : 0)
        }
        Spacer(minLength: 0)
        if let value = item.value { Text(value).foregroundStyle(Ink.secondary) }
      }
      if let subtitle = item.subtitle { Text(subtitle).foregroundStyle(Ink.secondary) }
    }
    .padding(.vertical, context.size(12)).padding(.horizontal, context.size(14))
    .overlay(alignment: .topTrailing) {
      if let icon = item.icon {
        Image(systemName: icon).font(.system(size: context.size(17))).foregroundStyle(Ink.secondary)
          .padding(.top, context.size(12)).padding(.trailing, context.size(14))
      }
    }
  }

  private var narrow: some View {
    VStack(spacing: context.size(4)) {
      if let label = item.label {
        Text(label).font(.system(size: context.size(PageMetrics.smallSize), weight: .medium)).foregroundStyle(
          Ink.secondary)
      }
      if item.icon != nil { PageIcon(item: item, size: context.size(26)) }
      if let title = item.title { Text(title).fontWeight(.semibold) }
      if let subtitle = item.subtitle { Text(subtitle).font(context.small).foregroundStyle(Ink.secondary) }
      if let value = item.value { Text(value).font(context.small).foregroundStyle(Ink.secondary) }
    }
    .lineLimit(1)
    .multilineTextAlignment(.center)
    .padding(.vertical, context.size(10)).padding(.horizontal, 4)
  }
}

/// Bars: the system's own, under their label and value. A lone bar takes the page's width; more share a
/// line, two or three across.
private struct PageProgresses: View {
  let items: [PageItem]
  @Environment(\.page) private var context

  var body: some View {
    PageColumns(
      minimum: items.count == 1 ? 0 : 160, spacing: context.size(24), rowSpacing: context.size(12), most: 3
    ) {
      ForEach(items.indices, id: \.self) { index in
        let item = items[index]
        VStack(alignment: .leading, spacing: context.size(5)) {
          HStack {
            Text(item.label ?? "").lineLimit(1)
            Spacer(minLength: 8)
            if let value = item.value { Text(value).foregroundStyle(Ink.secondary) }
          }
          // A program's percent can be computed from an empty total, so `nan` must not reach `Int`.
          let percent = item.percent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } ?? 0
          ProgressView(value: percent, total: 100).progressViewStyle(.linear)
            .tint(Color.accentColor)
            .accessibilityLabel(item.label ?? "")
            .accessibilityValue(item.value ?? "\(Int(percent)) percent")
        }
      }
    }
  }
}

private struct PageCard: View {
  let icon: String?
  let blocks: [PageBlock]
  @Environment(\.page) private var context

  var body: some View {
    PageBlocks(blocks: blocks, boxed: true)
      .padding(.vertical, context.size(12)).padding(.horizontal, context.size(14))
      .padding(.trailing, icon == nil ? 0 : 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .modifier(PageBox(selected: false))
      .overlay(alignment: .topTrailing) {
        if let icon {
          Image(systemName: icon).font(.system(size: context.size(17))).foregroundStyle(Ink.secondary)
            .padding(.top, context.size(12)).padding(.trailing, context.size(14))
        }
      }
  }
}

/// Canvas fields: the system's switch, slider and pickers in the page's row rhythm. The input keeps the
/// keyboard: using one hands it back (`PageContext.release`).
private struct PageFields: View {
  let controls: [Page.Control]
  @Environment(\.page) private var context
  @Environment(\.pageSelection) private var selection

  var body: some View {
    // In the rows' metrics, and selected as a row is, so arrowing from rows into fields reads as one list.
    VStack(spacing: 2) {
      ForEach(controls, id: \.name) { control in
        HStack(alignment: control.isText ? .top : .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(control.label)
            if control.isText, let description = control.definition.description, description != control.label
            {
              Text(description).font(context.small).foregroundStyle(Ink.secondary)
            }
          }
          .padding(.top, control.isText ? 5 : 0)
          Spacer(minLength: 12)
          PageControl(control: control)
        }
        .font(.system(size: 14 * context.scale))
        .padding(.horizontal, 10).padding(.vertical, 3)
        .frame(minHeight: context.rowHeight)
        .background {
          if selection == control.id {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.selection)
          }
        }
        .id(control.id)
      }
    }
    .padding(.horizontal, -10)
  }
}

private struct PageControl: View {
  let control: Page.Control
  @Environment(\.page) private var context
  /// A slider's value while it is dragged, ahead of the page that will show it.
  @State private var dragged: Double?

  var body: some View {
    switch control.control {
    case .text:
      VStack(alignment: .leading, spacing: 4) {
        let focused = context.focusedField == control.name
        SearchField(
          text: control.text, edit: { context.text(control.name, .edit($0.text)) },
          placeholder: control.definition.placeholder ?? "", size: context.size(14), focused: focused,
          onFocus: { context.text(control.name, .focus) }, onBlur: { context.text(control.name, .blur) },
          accessibilityName: control.label, preservesEditing: true
        )
        .id(context.turn)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Ink.surface, in: .rect(cornerRadius: 7))
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(focused ? Color.accentColor : Ink.primary.opacity(0.12), lineWidth: focused ? 2 : 1)
        }
        if let problem = control.problem {
          Text(problem).font(context.small).foregroundStyle(Ink.destructive)
        }
      }
      .frame(width: context.width * 0.45)
    case .toggle:
      Toggle(
        control.label, isOn: Binding(get: { control.value == "true" }, set: { commit($0 ? "true" : "false") })
      )
      .toggleStyle(.switch).labelsHidden()
    case .slider(let min, let max, let step):
      HStack(spacing: 10) {
        Slider(
          value: Binding(
            get: { dragged ?? Field.number(control.value) ?? min },
            set: {
              guard let value = control.sliderValue(at: Int((($0 - min) / step).rounded())),
                let number = Field.number(value)
              else { return }
              dragged = number
              context.change(.init(name: control.name, value: value, phase: .preview))
            }),
          in: min...max, step: step,
          onEditingChanged: { editing in
            guard !editing, let dragged else { return }
            self.dragged = nil
            commit(Field.wire(dragged))
          }
        )
        .frame(width: 180).labelsHidden().accessibilityLabel(control.label)
        Text(dragged.map(Field.wire) ?? control.value)
          .monospacedDigit().foregroundStyle(Ink.secondary).lineLimit(1)
          .frame(minWidth: context.size(34), alignment: .trailing)
          .accessibilityHidden(true)
      }
    case .choice(let options):
      let selection = Binding(get: { control.value }, set: { commit($0) })
      let picker = Picker(control.label, selection: selection) {
        ForEach(options, id: \.value) { Text($0.label).lineLimit(1).tag($0.value) }
      }.labelsHidden()
      ViewThatFits(in: .horizontal) {
        if options.count <= 4 {
          picker.pickerStyle(.segmented).fixedSize()
        }
        picker.pickerStyle(.menu).frame(maxWidth: context.width * 0.52, alignment: .trailing)
      }
      .frame(maxWidth: context.width * 0.56, alignment: .trailing)
    }
  }

  private func commit(_ value: String) {
    context.change(.init(name: control.name, value: value, phase: .commit))
    context.release()
  }
}

/// The clipboard writes a distinct path per picture. Share its size and the decoded thumbnail
/// between the measuring view, the visible view and prefetching the neighboring rows.
@MainActor enum PagePictures {
  final class Picture {
    let size: CGSize
    var thumbnail: Task<CGImage?, Never>?

    init(size: CGSize) { self.size = size }
  }

  private static let cache: NSCache<NSURL, Picture> = {
    let cache = NSCache<NSURL, Picture>()
    cache.countLimit = 8
    return cache
  }()

  static func picture(_ url: URL) -> Picture? {
    if let picture = cache.object(forKey: url as NSURL) { return picture }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
      width > 0, height > 0
    else { return nil }
    let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
    let scale = min(0.5, 360 / max(width, height))
    let picture = Picture(
      size: CGSize(
        width: (rotated ? height : width) * scale, height: (rotated ? width : height) * scale))
    cache.setObject(picture, forKey: url as NSURL)
    return picture
  }

  static func thumbnail(_ url: URL) -> Task<CGImage?, Never>? {
    guard let picture = picture(url) else { return nil }
    if let thumbnail = picture.thumbnail { return thumbnail }
    let thumbnail = Task.detached(priority: .utility) {
      let options =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 720,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
    picture.thumbnail = thumbnail
    return thumbnail
  }
}

private struct PagePicture: View {
  let url: URL
  let spacing: CGFloat
  let loadsImage: Bool
  @State private var thumbnail: (URL, CGImage)?

  var body: some View {
    if let picture = PagePictures.picture(url) {
      let scale = min(1, 240 / picture.size.height)
      let size = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
      Color.clear.aspectRatio(size, contentMode: .fit)
        .frame(maxWidth: size.width)
        .overlay {
          if let (source, image) = thumbnail, source == url {
            Image(decorative: image, scale: 2).resizable().scaledToFit()
          }
        }
        .padding(.bottom, spacing)
        .task(id: url) {
          guard loadsImage, let image = await PagePictures.thumbnail(url)?.value, !Task.isCancelled else {
            return
          }
          thumbnail = (url, image)
        }
    }
  }
}

/// Equal cells side by side, as many as fit at `minimum` up to `most`, wrapping onto more lines; each
/// line as tall as its tallest cell.
struct PageColumns: Layout {
  var minimum: CGFloat
  var spacing: CGFloat
  var rowSpacing: CGFloat?
  var most = Int.max

  private func columns(_ width: CGFloat, _ count: Int) -> Int {
    guard minimum > 0 else { return 1 }
    return max(1, min(count, most, Int((width + spacing) / (minimum + spacing))))
  }

  private func lines(_ width: CGFloat, _ subviews: Subviews) -> (
    cell: CGFloat, heights: [CGFloat], count: Int
  ) {
    let count = columns(width, subviews.count)
    let cell = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    let heights = stride(from: 0, to: subviews.count, by: count).map { start in
      subviews[start..<min(subviews.count, start + count)].map {
        $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
      }.max() ?? 0
    }
    return (cell, heights, count)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 640
    let (_, heights, _) = lines(width, subviews)
    return CGSize(
      width: width,
      height: heights.reduce(0, +) + (rowSpacing ?? spacing) * CGFloat(max(0, heights.count - 1)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (cell, heights, count) = lines(bounds.width, subviews)
    var y = bounds.minY
    for (line, height) in heights.enumerated() {
      for column in 0..<count where line * count + column < subviews.count {
        subviews[line * count + column].place(
          at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
          proposal: ProposedViewSize(width: cell, height: height))
      }
      y += height + (rowSpacing ?? spacing)
    }
  }
}

/// Badges in a line that wraps.
struct PageFlow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = place(proposal.width ?? .infinity, subviews)
    return CGSize(
      width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (frame, subview) in zip(place(bounds.width, subviews), subviews) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
    }
  }

  private func place(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += line + spacing
        line = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      line = max(line, size.height)
    }
    return frames
  }
}
