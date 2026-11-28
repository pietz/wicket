import AppKit
import Observation
import SwiftUI

/// The page shown and its height. The panel measures and commits them in the same turn.
@MainActor @Observable
final class NativePageRenderer {
  private(set) var document = PageDocument()
  private(set) var height: Double = PaletteLayout.answerMin
  /// Before the panel's bounds. Past the cap, at least this much content.
  @ObservationIgnored private(set) var contentHeight: Double = 0
  private(set) var renderedTurn = ""
  private(set) var streamLength = 0
  @ObservationIgnored private var streaming = false
  var cap: Double = PaletteLayout.answerMax
  var selected: String?
  var focusedField: String?
  private(set) var width = PaletteLayout.pageWidth
  private(set) var textSize = Configuration.TextSize.medium
  @ObservationIgnored var onTarget: ((String, String) -> Void)?
  @ObservationIgnored var onFieldChange: ((Page.Control.Change, String) -> Void)?
  @ObservationIgnored var onText: ((String, PageContext.TextEvent, String) -> Void)?
  @ObservationIgnored var onFieldFocus: ((String) -> Void)?
  @ObservationIgnored let open: @MainActor (URL) -> Void
  @ObservationIgnored private var source: Page?
  @ObservationIgnored private var icons: [String: ExtensionIcons.Version] = [:]
  @ObservationIgnored private var appearance: NSAppearance?
  @ObservationIgnored private var measuredCap: Double = 0
  /// Where a page was left, so going back to it returns there.
  @ObservationIgnored var positions: [String: CGFloat] = [:]
  @ObservationIgnored private lazy var measurer = NSHostingController(rootView: AnyView(EmptyView()))

  init(open: @escaping @MainActor (URL) -> Void = { _ in }) {
    self.open = open
  }

  var context: PageContext {
    let revision = document.revision
    let turn = renderedTurn
    return PageContext(
      scale: textSize.scale, rowHeight: textSize.rowHeight, width: width, revision: revision, turn: turn,
      focusedField: focusedField, text: { [weak self] name, event in self?.onText?(name, event, turn) },
      open: open,
      click: { [weak self] id in
        guard let self else { return }
        onTarget?(id, revision)
      },
      change: { [weak self] change in
        guard let self else { return }
        onFieldChange?(change, turn)
      },
      release: { [weak self] in
        guard let self else { return }
        onFieldFocus?(turn)
      })
  }

  func update(
    _ page: Page, turn: String, streaming: Bool = false, width: CGFloat = PaletteLayout.pageWidth,
    textSize: Configuration.TextSize = .medium, appearance: NSAppearance = .currentDrawing()
  ) {
    let reset = turn != renderedTurn
    if reset, positions.count > 16 { positions.removeAll() }
    let changed = source != page || self.streaming != streaming || reset
    let sizeChanged =
      self.width != width || self.textSize != textSize
      || self.appearance != appearance || measuredCap != cap
    guard changed || sizeChanged else { return }

    self.width = width
    self.textSize = textSize
    self.appearance = appearance
    self.streaming = streaming
    renderedTurn = turn
    measuredCap = cap
    if changed {
      if source?.iconRequests != page.iconRequests || reset {
        icons = page.iconRequests.mapValues(\.version)
      }
      source = page
      streamLength = streaming ? page.source.utf8.count : 0
      let next = PageDocument(page, turn: turn, streaming: streaming, icons: icons)
      if next != document { document = next }
    }
    contentHeight = measure(document, appearance: appearance)
    height = PaletteLayout.answerHeight(
      contentHeight, previous: reset ? PaletteLayout.answerMin : height, streaming: streaming, cap: cap)
  }

  func refreshExtensionIcons() {
    guard let source else { return }
    let versions = source.iconRequests.mapValues(\.version)
    guard versions != icons else { return }
    icons = versions
    document = PageDocument(source, turn: renderedTurn, streaming: streaming, icons: versions)
  }

  /// The ideal height of a growing prefix, to avoid laying out content beyond the panel's cap.
  private func measure(_ document: PageDocument, appearance: NSAppearance) -> Double {
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    measurer.view.appearance = appearance
    var count = 8
    while true {
      var prefix = document
      prefix.blocks = Array(document.blocks.prefix(count))
      measurer.rootView = AnyView(
        PageBody(document: prefix).fixedSize(horizontal: false, vertical: true)
          .environment(\.page, context).environment(\.colorScheme, dark ? .dark : .light))
      let height = measurer.sizeThatFits(in: CGSize(width: width, height: 100_000)).height
      if height > cap || count >= document.blocks.count { return height }
      count *= 4
    }
  }
}

/// The displayed page remembers each turn's offset, follows a stream at the bottom and reveals targets.
struct NativePageView: View {
  let renderer: NativePageRenderer
  @State private var position = ScrollPosition(edge: .top)
  @State private var displayedTurn = ""
  @State private var followsTail = true
  @State private var userIsScrolling = false

  private struct Location: Equatable {
    let turn: String
    let selection: String?
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        PageBody(document: renderer.document, lazy: true)
      }
      .scrollPosition($position)
      .onScrollPhaseChange { _, phase in
        userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      }
      .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
        guard displayedTurn == renderer.renderedTurn else { return }
        renderer.positions[displayedTurn] = new.contentOffset.y
        // Layout growth doesn't change where the user chose to read.
        if userIsScrolling || old.contentSize == new.contentSize && old.contentOffset != new.contentOffset {
          followsTail = new.contentSize.height - new.visibleRect.maxY < 24
        }
      }
      .onChange(of: renderer.streamLength) { old, new in
        if new > old, displayedTurn == renderer.renderedTurn, followsTail, !userIsScrolling,
          renderer.selected == nil
        {
          position.scrollTo(edge: .bottom)
        }
      }
      .onChange(of: Location(turn: renderer.renderedTurn, selection: renderer.selected), initial: true) {
        _, location in
        if displayedTurn != location.turn {
          displayedTurn = location.turn
          let saved = renderer.positions[location.turn]
          followsTail = saved == nil
          position.scrollTo(y: saved ?? 0)
          if saved != nil { return }
        }
        guard let id = location.selection else { return }
        // Build the containing block first if it is below the fold. TextKit then reveals its own range.
        let blocks = renderer.document.blocks
        if let block = blocks.firstIndex(where: { $0.holds(id) }),
          let segment = PageBlocks.segments(blocks).first(where: { $0.contains(block) })
        {
          proxy.scrollTo(
            PageBlocks.id(segment.lowerBound, in: blocks, lazy: !renderer.document.hasTextFields))
          DispatchQueue.main.async { [weak renderer = renderer] in
            guard renderer?.selected == id else { return }
            proxy.scrollTo(id)
          }
        }
      }
      .environment(\.page, renderer.context)
      .environment(\.pageSelection, renderer.selected)
    }
  }
}
