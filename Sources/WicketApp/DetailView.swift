import SwiftUI
import WicketCore

/// A detail frame: the markdown page with its metadata. The title is in the pill and the actions in
/// the footer and the action panel (⌘K).
///
/// The metadata's place follows one rule (`DetailLayout`): a 180 pt column beside the text when the
/// text is taller than the column, else a two-column table under the text, full width. Both
/// heights are measured at the column's widths whichever way the page is drawn (the one not drawn
/// by a hidden copy, which only a short page needs), so the choice never flips back and forth.
///
/// The card fits the page: `onMeasure` gets the content's height whenever it changes, laid out at
/// the card's width inside the scroll views, so it doesn't depend on the card's height and
/// resizing the card never measures again.
struct DetailView: View {
    static let metadataWidth: CGFloat = 180
    let detail: Detail
    let textSize: TextSize
    let onMeasure: (CGFloat) -> Void
    /// The page's content as drawn: the text, and the table under it when there is one.
    @State private var pageHeight: CGFloat = 0
    /// The text laid out beside the column, and the column; nil until measured.
    @State private var textBeside: CGFloat?
    @State private var columnHeight: CGFloat?
    @State private var width: CGFloat = 0

    private var sidebar: Bool {
        !detail.metadata.isEmpty && DetailLayout.usesSidebar(text: textBeside, metadata: columnHeight)
    }

    var body: some View {
        Group {
            if sidebar {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        markdown
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                                pageHeight = $0
                                textBeside = $0
                            }
                    }
                    Divider()
                    ScrollView {
                        MetadataColumn(metadata: detail.metadata, textSize: textSize)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { columnHeight = $0 }
                    }
                    .frame(width: Self.metadataWidth)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        markdown
                        if !detail.metadata.isEmpty {
                            MetadataTable(metadata: detail.metadata, textSize: textSize)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)
                                .padding(.bottom, 18)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
                }
                .background(alignment: .topLeading) {
                    if !detail.metadata.isEmpty { hiddenSidebar }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .scrollIndicators(.never)
        .textSelection(.enabled)
        .onChange(of: measured, initial: true) { _, height in
            if height > 0 { onMeasure(height) }
        }
    }

    /// The content's height: the taller of the text and the column beside it, or the page.
    private var measured: CGFloat {
        sidebar ? max(pageHeight, columnHeight ?? 0) : pageHeight
    }

    private var markdown: some View {
        MarkdownView(blocks: MarkdownBlock.parse(detail.markdown), textSize: textSize)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The text and the column as the sidebar would lay them out, measured but never shown, so a
    /// page drawn full width still knows when its text grows taller than the column.
    private var hiddenSidebar: some View {
        HStack(alignment: .top, spacing: 0) {
            markdown
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { textBeside = $0 }
                .frame(width: max(width - Self.metadataWidth - 1, 0))
            MetadataColumn(metadata: detail.metadata, textSize: textSize)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { columnHeight = $0 }
                .frame(width: Self.metadataWidth)
        }
        .hidden()
        .accessibilityHidden(true)
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

/// Metadata as a table under the text: labels in one column, values in the other.
private struct MetadataTable: View {
    let metadata: [Detail.Metadata]
    let textSize: TextSize

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 8) {
            ForEach(Array(metadata.enumerated()), id: \.offset) { _, entry in
                GridRow {
                    Text(entry.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(entry.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: textSize.points(13)))
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
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).fontWeight(index == 0 ? .semibold : nil)
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
        case .rule:
            Divider()
        }
    }
}

extension TextSize {
    /// A size designed for small text (body 13), scaled to this step's body.
    func points(_ small: CGFloat) -> CGFloat {
        (small * bodySize / TextSize.small.bodySize).rounded()
    }
}
