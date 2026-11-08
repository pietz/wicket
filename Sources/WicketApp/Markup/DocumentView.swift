import SwiftUI
import WicketCore

/// A page: its document (prose and native components in reading order) in one scroll, with an
/// extension page's metadata. The title is in the pill and the actions in the footer and the action
/// panel (⌘K).
///
/// The selected target (`DocumentFocus.selected`) is scrolled into view as the arrows move; with
/// nothing to select the arrows scroll the page (`scroll`, a line per press).
///
/// The metadata's place follows one rule (`DetailLayout`): a 180 pt column beside the document when
/// the document is taller than the column, else a two-column table under it, full width. Both
/// heights are measured at the column's widths whichever way the page is drawn (the one not drawn
/// by a hidden copy, which only a short page needs), so the choice never flips back and forth.
///
/// The card fits the page: `onMeasure` gets the content's height whenever it changes, laid out at
/// the card's width inside the scroll views, so it doesn't depend on the card's height and
/// resizing the card never measures again.
struct DocumentView: View {
    static let metadataWidth: CGFloat = 180
    /// The page's inset from the card's edge.
    static let inset = EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20)
    let document: WicketCore.Document
    let metadata: [Detail.Metadata]
    let textSize: TextSize
    /// The latest press of the arrows; one that moved no selection scrolls a line per step.
    let navigation: Navigation?
    let onMeasure: (CGFloat) -> Void
    @Environment(\.documentFocus) private var focus
    /// The page's content as drawn: the document, and the table under it when there is one.
    @State private var pageHeight: CGFloat = 0
    /// The document laid out beside the column, and the column; nil until measured.
    @State private var textBeside: CGFloat?
    @State private var columnHeight: CGFloat?
    @State private var width: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0

    private var sidebar: Bool {
        !metadata.isEmpty && DetailLayout.usesSidebar(text: textBeside, metadata: columnHeight)
    }

    var body: some View {
        Group {
            if sidebar {
                HStack(alignment: .top, spacing: 0) {
                    scrolling {
                        page
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                                pageHeight = $0
                                textBeside = $0
                            }
                    }
                    Divider()
                    ScrollView {
                        MetadataColumn(metadata: metadata, textSize: textSize)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { columnHeight = $0 }
                    }
                    .frame(width: Self.metadataWidth)
                }
            } else {
                scrolling {
                    VStack(alignment: .leading, spacing: 0) {
                        page
                        if !metadata.isEmpty {
                            LabelValueGrid(pairs: metadata.map { ($0.label, $0.value) })
                                .padding(.horizontal, 20)
                                .padding(.top, 4)
                                .padding(.bottom, 18)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
                }
                .background(alignment: .topLeading) {
                    if !metadata.isEmpty { hiddenSidebar }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .scrollIndicators(.never)
        .environment(\.textSize, textSize)
        .onChange(of: measured, initial: true) { _, height in
            if height > 0 { onMeasure(height) }
        }
    }

    /// The content's height: the taller of the document and the column beside it, or the page.
    private var measured: CGFloat {
        sidebar ? max(pageHeight, columnHeight ?? 0) : pageHeight
    }

    private var page: some View {
        DocumentBlocks(blocks: document.blocks)
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// The page's scroll view, following the selection and the arrows.
    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        let content = content()
        return ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { offset = $1 }
            // The system's soft edge where the page passes under the footer.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // Back from a pushed page, or redrawn in the other layout: the selection stays in view.
            .onAppear {
                if let selected = focus.selected { proxy.scrollTo(selected) }
            }
            .onChange(of: focus.selected) { _, selected in
                withAnimation(.snappy(duration: 0.2)) {
                    if let selected { proxy.scrollTo(selected) } else { position.scrollTo(edge: .top) }
                }
            }
            .onChange(of: navigation) { _, navigation in
                guard let navigation, !navigation.moved else { return }
                let line = textSize.points(13) * 3
                withAnimation(.snappy(duration: 0.2)) {
                    position.scrollTo(y: max(0, offset + CGFloat(navigation.delta) * line))
                }
            }
        }
    }

    /// The document and the column as the sidebar would lay them out, measured but never shown, so
    /// a page drawn full width still knows when its document grows taller than the column.
    private var hiddenSidebar: some View {
        HStack(alignment: .top, spacing: 0) {
            page
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { textBeside = $0 }
                .frame(width: max(width - Self.metadataWidth - 1, 0))
            MetadataColumn(metadata: metadata, textSize: textSize)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { columnHeight = $0 }
                .frame(width: Self.metadataWidth)
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

/// A press of the arrows: by how much, and whether it moved the selection. `serial` makes each
/// press a change. Initial positioning (a new list at its top) is not navigation.
struct Navigation: Equatable {
    var serial: Int
    var delta: Int
    var moved: Bool

    /// Where a list goes after this press: its top (the summary above the rows) when Up stayed on
    /// the first row; else its selected row, revealed, so a row below a tall summary is clamped to
    /// the bottom rather than left under it.
    var showsListTop: Bool { !moved && delta < 0 }
}

/// Blocks in reading order: prose, text shown as written, and each component as its registered
/// view (`ComponentViews`). A component that holds blocks (a card, a column) draws them with this.
struct DocumentBlocks: View {
    let blocks: [WicketCore.Document.Block]
    /// The gap between blocks: a page's, or a card's tighter one.
    var spacing: CGFloat = 16
    @Environment(\.textSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: spacing * textSize.scale) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    MarkdownView(blocks: markdown.blocks, textSize: textSize)
                case .text(let text):
                    Text(verbatim: text)
                        .font(.system(size: textSize.points(12), design: .monospaced))
                        .foregroundStyle(.secondary)
                case .component(let component):
                    ComponentViews.view(for: component)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where a page's metadata goes (docs/extensions.md, "Level 2: a detail view").
enum DetailLayout {
    /// Beside the text when the text (laid out beside the column) is taller than the column; before
    /// either is measured, beside, where both can be.
    static func usesSidebar(text: CGFloat?, metadata: CGFloat?) -> Bool {
        guard let text, let metadata else { return true }
        return text > metadata
    }
}

/// Metadata as a column of label over value.
private struct MetadataColumn: View {
    let metadata: [Detail.Metadata]
    let textSize: TextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(metadata.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .font(.system(size: textSize.points(11)))
                        .foregroundStyle(.secondary)
                    Text(entry.value)
                        .font(.system(size: textSize.points(13)))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Markdown blocks, each drawn on its own: `Text` keeps the inline styles (emphasis, code, links).
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let textSize: TextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacing(before: index))
            }
        }
        .font(.system(size: textSize.points(13)))
    }

    /// List items sit close together; other blocks get a paragraph's gap.
    private func spacing(before index: Int) -> CGFloat {
        if case .listItem = blocks[index], case .listItem = blocks[index - 1] { 4 } else { 10 }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text)
                .font(
                    .system(size: textSize.points(level == 1 ? 20 : level == 2 ? 16 : 14), weight: .semibold)
                )
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(text)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .code(let code):
            Text(code)
                .font(.system(size: textSize.points(12), design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 3)
                }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(cell)
                                .fontWeight(index == 0 ? .semibold : nil)
                                .foregroundStyle(index > 0 && column == 0 ? .secondary : .primary)
                        }
                    }
                    if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .monospacedDigit()
        case .rule:
            Divider()
        }
    }
}
