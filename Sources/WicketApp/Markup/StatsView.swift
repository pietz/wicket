import SwiftUI
import WicketCore

/// `<stat>`s: one stands plain, larger; several form a strip of tiles, up to four per line, under
/// the strip's title.
struct StatsView: ComponentView {
    let node: Stats
    @Environment(\.textSize) private var textSize

    init(_ node: Stats) { self.node = node }

    /// The most tiles on a line.
    static let perLine = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * textSize.scale) {
            if let title = node.title { GroupHeading(title: title) }
            if node.stats.count == 1 {
                StatCell(stat: node.stats[0], valueSize: 26)
            } else {
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                    count: min(node.stats.count, Self.perLine))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Array(node.stats.enumerated()), id: \.offset) { _, stat in
                        StatCell(stat: stat, valueSize: 18)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .surface(radius: 12)
                    }
                }
            }
        }
    }
}

/// One stat: its label (with its symbol), the value in the tone's color, a detail line.
private struct StatCell: View {
    let stat: Stats.Stat
    let valueSize: CGFloat
    @Environment(\.textSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = stat.label {
                HStack(spacing: 4) {
                    SymbolImage(name: stat.icon)
                        .symbolRenderingMode(.multicolor)
                    Text(label)
                }
                .font(.system(size: textSize.points(11)))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if stat.label == nil { SymbolImage(name: stat.icon).symbolRenderingMode(.multicolor) }
                Text(stat.value)
                    .foregroundStyle(ToneStyle.style(stat.tone, else: .primary))
            }
            .font(.system(size: textSize.points(valueSize), weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let detail = stat.detail {
                Text(detail)
                    .font(.system(size: textSize.points(12)))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
