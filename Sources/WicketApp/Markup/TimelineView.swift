import SwiftUI
import WicketCore

/// `<event>`s on a rail under their timeline's title: the time at the left, a dot on the rail, what
/// happens and where. An event with a target is one: Return opens it.
struct TimelineView: ComponentView {
    let node: Timeline
    @Environment(\.textSize) private var textSize

    init(_ node: Timeline) { self.node = node }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * textSize.scale) {
            if let title = node.title { GroupHeading(title: title) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(node.events.enumerated()), id: \.offset) { index, event in
                    EventRow(event: event, isFirst: index == 0, isLast: index == node.events.count - 1)
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: Timeline.Event
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.textSize) private var textSize

    var body: some View {
        let dot = 8 * textSize.scale
        let dotTop = 4 * textSize.scale
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                if let time = event.time { Text(time) }
                if let end = event.end { Text(end).foregroundStyle(.tertiary) }
            }
            .font(.system(size: textSize.points(12)).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44 * textSize.scale, alignment: .trailing)
            .padding(.top, 1)
            // The rail: a line through every event and a dot at each.
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.5)
                .frame(width: dot, height: dot)
                .padding(.top, dotTop)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .padding(.top, isFirst ? dotTop + dot / 2 : 0)
                        .frame(maxHeight: isLast ? dotTop + dot / 2 : .infinity, alignment: .top)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: textSize.points(13), weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: textSize.points(12)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 13 * textSize.scale)
            Spacer(minLength: 0)
            if event.target != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: textSize.points(10), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, dotTop)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        // A selectable event's highlight reaches past the text around it, as a row's does.
        .padding(.horizontal, event.target == nil ? 0 : 8)
        .padding(.vertical, event.target == nil ? 0 : 4)
        .target(event.target)
        .padding(.horizontal, event.target == nil ? 0 : -8)
    }
}
