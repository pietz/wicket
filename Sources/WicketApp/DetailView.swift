import SwiftUI
import WicketCore

/// A detail frame: the markdown page, with its metadata in a column beside it. The title is in the
/// pill and the actions in the footer and the action panel (⌘K).
///
/// The card fits the page: `onMeasure` gets the content's height (the taller of the page and the
/// metadata column) whenever it changes, laid out at the card's width inside the scroll views, so
/// it doesn't depend on the card's height and resizing the card never measures again.
struct DetailView: View {
    static let metadataWidth: CGFloat = 180
    let detail: Detail
    let textSize: TextSize
    let onMeasure: (CGFloat) -> Void
    @State private var pageHeight: CGFloat = 0
    @State private var metadataHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                MarkdownView(blocks: MarkdownBlock.parse(detail.markdown), textSize: textSize)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
            }
            if !detail.metadata.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(detail.metadata.enumerated()), id: \.offset) { _, entry in
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
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { metadataHeight = $0 }
                }
                .frame(width: Self.metadataWidth)
            }
        }
        .scrollIndicators(.never)
        .textSelection(.enabled)
        .onChange(of: max(pageHeight, detail.metadata.isEmpty ? 0 : metadataHeight)) { _, height in
            onMeasure(height)
        }
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
