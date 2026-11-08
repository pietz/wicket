import SwiftUI
import WicketCore

/// `<columns>`: up to three columns of equal width side by side and top aligned, stacked one per
/// row when each would be narrower than `minimumWidth` scaled to the text, which larger text sizes
/// reach sooner. `ViewThatFits` picks the side-by-side grid while its columns' ideal widths fit.
struct ColumnsView: ComponentView {
    let node: Columns
    @Environment(\.textSize) private var textSize

    /// The narrowest a column may be at small text; it grows with the text size.
    static let minimumWidth: CGFloat = 150

    init(_ node: Columns) { self.node = node }

    var body: some View {
        let spacing = 12 * textSize.scale
        let minimum = Self.minimumWidth * textSize.scale
        let columns = Array(node.columns.enumerated())
        ViewThatFits(in: .horizontal) {
            if columns.count > 1 {
                Grid(alignment: .topLeading, horizontalSpacing: spacing) {
                    GridRow {
                        ForEach(columns, id: \.offset) { _, blocks in
                            DocumentBlocks(blocks: blocks, spacing: 12)
                                .frame(
                                    minWidth: minimum, idealWidth: minimum, maxWidth: .infinity,
                                    alignment: .topLeading)
                        }
                    }
                }
            }
            Grid(alignment: .topLeading, verticalSpacing: spacing) {
                ForEach(columns, id: \.offset) { _, blocks in
                    GridRow { DocumentBlocks(blocks: blocks, spacing: 12) }
                }
            }
        }
        .environment(\.inColumn, true)
    }
}
