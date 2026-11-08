import SwiftUI
import WicketCore

/// `<columns>`: up to three columns of equal width side by side, stacked when each would be too
/// narrow for its text (`ColumnsLayout.stacks`), which larger text sizes reach sooner.
struct ColumnsView: ComponentView {
    let node: Columns
    @Environment(\.textSize) private var textSize

    init(_ node: Columns) { self.node = node }

    var body: some View {
        ColumnsLayout(textSize: textSize, spacing: 12 * textSize.scale) {
            ForEach(Array(node.columns.enumerated()), id: \.offset) { _, blocks in
                DocumentBlocks(blocks: blocks, spacing: 12)
            }
        }
        .environment(\.inColumn, true)
    }
}

/// Columns side by side, each the same width and top aligned; one above the other once a column
/// would be narrower than `minimumWidth`.
struct ColumnsLayout: Layout {
    let textSize: TextSize
    let spacing: CGFloat

    /// The narrowest a column may be at small text; it grows with the text size.
    static let minimumWidth: CGFloat = 150

    /// Whether `count` columns stack at `width` and `textSize`: when each would be narrower than
    /// `minimumWidth` scaled to the text.
    static func stacks(count: Int, width: CGFloat, textSize: TextSize, spacing: CGFloat = 12) -> Bool {
        guard count > 1 else { return true }
        let column = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return column < minimumWidth * textSize.scale
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        if stacked(width, subviews) {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + gaps(subviews))
        }
        let column = columnWidth(width, subviews)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
            .max()
        return CGSize(width: width, height: height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if stacked(bounds.width, subviews) {
            var y = bounds.minY
            for subview in subviews {
                let size = ProposedViewSize(width: bounds.width, height: nil)
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: size)
                y += subview.sizeThatFits(size).height + spacing
            }
            return
        }
        let column = columnWidth(bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (column + spacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: column, height: nil))
        }
    }

    private func stacked(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        Self.stacks(count: subviews.count, width: width, textSize: textSize, spacing: spacing)
    }

    private func columnWidth(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(subviews.count - 1, 0)) }
}
