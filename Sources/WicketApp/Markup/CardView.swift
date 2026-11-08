import SwiftUI
import WicketCore

/// `<card>`: blocks about one subject on the inset surface under a heading. With a target the whole
/// card is one: Return opens it, and a small arrow says so.
struct CardView: ComponentView {
    let node: Card
    @Environment(\.textSize) private var textSize

    init(_ node: Card) { self.node = node }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * textSize.scale) {
            if node.title != nil || node.subtitle != nil || node.icon != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SymbolImage(name: node.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = node.title {
                            Text(title)
                                .font(.system(size: textSize.points(13), weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let subtitle = node.subtitle {
                            Text(subtitle)
                                .font(.system(size: textSize.points(12)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if node.target != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: textSize.points(10), weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            DocumentBlocks(blocks: node.blocks, spacing: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 14)
        .accessibilityElement(children: node.target == nil ? .contain : .combine)
        .target(node.target, radius: 14)
    }
}
