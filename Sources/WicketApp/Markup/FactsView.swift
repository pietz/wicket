import SwiftUI
import WicketCore

/// `<fact>`s: a table of labels and values under its title.
struct FactsView: ComponentView {
    let node: Facts
    @Environment(\.textSize) private var textSize

    init(_ node: Facts) { self.node = node }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * textSize.scale) {
            if let title = node.title { GroupHeading(title: title) }
            LabelValueGrid(pairs: node.facts.map { ($0.label, $0.value) })
        }
    }
}

/// Labels in one column, values in the other: a `<facts>` group, and an extension page's metadata
/// under its text.
struct LabelValueGrid: View {
    let pairs: [(label: String, value: String)]
    @Environment(\.textSize) private var textSize

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(pair.value)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: textSize.points(13)))
    }
}
