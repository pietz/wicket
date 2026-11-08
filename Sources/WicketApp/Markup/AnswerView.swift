import SwiftUI
import WicketCore

/// `<answer>`: one short answer shown large, its detail under it; a target whose Return copies it.
struct AnswerView: ComponentView {
    let node: Answer
    @Environment(\.textSize) private var textSize

    init(_ node: Answer) { self.node = node }

    var body: some View {
        HStack(spacing: 12) {
            if case .symbol(let name) = node.item.icon, name != Answer.tags[0].icon {
                SymbolImage(name: name)
                    .font(.system(size: textSize.points(22)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.item.title)
                    .font(.system(size: textSize.points(30), weight: .semibold).monospacedDigit())
                if let detail = node.item.subtitle {
                    Text(detail)
                        .font(.system(size: textSize.points(12)))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        // The highlight reaches past the text around it, as a row's does.
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .target(node.item)
        .padding(.horizontal, -10)
    }
}
