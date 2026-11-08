import SwiftUI
import WicketCore

/// `<callout>`: a short note tinted by its tone, with the tone's symbol.
struct CalloutView: ComponentView {
    let node: Callout
    @Environment(\.textSize) private var textSize

    init(_ node: Callout) { self.node = node }

    var body: some View {
        let color = ToneStyle.color(node.tone)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Callout.symbols[node.tone] ?? "info.circle")
                .foregroundStyle(color)
                .font(.system(size: textSize.points(13), weight: .medium))
                .accessibilityLabel(node.tone.rawValue.capitalized)
            MarkdownView(blocks: node.markdown.blocks, textSize: textSize)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
