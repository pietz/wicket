import SwiftUI
import WicketCore

/// A list's summary above its rows: markup drawn as a document with nothing in it selectable (the
/// arrows belong to the rows), scrolling with them. It reports its height once laid out, so the
/// card makes room for it (up to `PaletteMetrics.maxListTop`).
struct ListTop: View {
    let summary: WicketCore.Document
    let textSize: TextSize
    let onMeasure: (CGFloat) -> Void

    var body: some View {
        DocumentBlocks(blocks: summary.blocks, spacing: 12)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.textSize, textSize)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { onMeasure($0) }
    }
}

/// A section's title above its first row: small and secondary, a heading for VoiceOver, never
/// selected (the arrows move through rows only).
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(height: PaletteMetrics.sectionHeaderHeight)
            .accessibilityAddTraits(.isHeader)
    }
}
