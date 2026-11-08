import SwiftUI
import WicketCore

/// `<badge>`s: short status labels in a row that wraps, tinted by their tones.
struct BadgesView: ComponentView {
    let node: Badges
    @Environment(\.textSize) private var textSize

    init(_ node: Badges) { self.node = node }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(node.badges.enumerated()), id: \.offset) { _, badge in
                Text(badge.text)
                    .font(.system(size: textSize.points(11), weight: .semibold))
                    .foregroundStyle(ToneStyle.style(badge.tone, else: .secondary))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        badge.tone.map { ToneStyle.color($0).opacity(0.14) } ?? Color.primary.opacity(0.06),
                        in: .capsule)
            }
        }
    }
}

/// Views in rows, left to right, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
