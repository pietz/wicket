import SwiftUI
import WicketCore

/// `<progress>`: what is progressing and how far, over a bar in the tone's color.
struct ProgressBarView: ComponentView {
    let node: WicketCore.Progress
    @Environment(\.textSize) private var textSize

    init(_ node: WicketCore.Progress) { self.node = node }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * textSize.scale) {
            HStack(alignment: .firstTextBaseline) {
                if let label = node.label { Text(label) }
                Spacer(minLength: 8)
                Text(amount)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: textSize.points(12)))
            SwiftUI.ProgressView(value: node.fraction)
                .progressViewStyle(.linear)
                .tint(node.tone.map(ToneStyle.color) ?? .accentColor)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.label ?? "Progress")
        .accessibilityValue(amount)
    }

    /// How far, as Copy Answer says it: a fraction as a percentage, else the value of the whole.
    private var amount: String {
        if node.max == 1 { return node.fraction.formatted(.percent.precision(.fractionLength(0))) }
        if node.max == 100 { return "\(node.value.formatted())%" }
        return "\(node.value.formatted()) of \(node.max.formatted())"
    }
}
