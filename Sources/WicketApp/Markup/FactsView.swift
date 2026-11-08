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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(Array(node.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(fact.value)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: textSize.points(13)))
        }
    }
}
