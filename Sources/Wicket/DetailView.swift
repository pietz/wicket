import SwiftUI
import WicketCore

/// A detail frame: the markdown page, with its metadata in a column beside it. The title is in the
/// pill and the actions in the footer and the action panel (⌘K).
struct DetailView: View {
    static let metadataWidth: CGFloat = 180
    let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                MarkdownView(blocks: MarkdownBlock.parse(detail.markdown))
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !detail.metadata.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(detail.metadata.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(entry.value)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: Self.metadataWidth)
            }
        }
        .scrollIndicators(.never)
        .textSelection(.enabled)
    }
}

/// Markdown blocks, each drawn on its own: `Text` keeps the inline styles (emphasis, code, links).
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacing(before: index))
            }
        }
        .font(.system(size: 13))
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
                .font(.system(size: level == 1 ? 20 : level == 2 ? 16 : 14, weight: .semibold))
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
                .font(.system(size: 12, design: .monospaced))
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
