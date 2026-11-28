import SwiftUI

struct NativeTimeline: View {
  let timeline: Timeline
  @Environment(\.page) private var context
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { geometry in
      let gutter = context.size(49)
      let width = max(0, geometry.size.width - gutter)
      let laneWidth = width / CGFloat(timeline.lanes.count)
      let header = context.size(27)
      let top = header + context.size(7)
      let height = max(1, geometry.size.height - top - context.size(10))
      let placements = timeline.placements(height: height, minimum: context.size(14))
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Ink.tertiary.opacity(0.15)).frame(width: width, height: 1)
          .offset(x: gutter, y: header)
        ForEach(timeline.lanes.indices, id: \.self) { index in
          Text(timeline.lanes[index]).font(context.small.weight(.semibold)).lineLimit(1)
            .foregroundStyle(index == timeline.nowLane ? Color.accentColor : Ink.primary)
            .frame(width: laneWidth, height: header)
            .offset(x: gutter + CGFloat(index) * laneWidth)
        }
        ForEach(0...timeline.lanes.count, id: \.self) { index in
          Rectangle().fill(Ink.tertiary.opacity(0.15))
            .frame(width: 1, height: height + top - header)
            .offset(x: gutter + CGFloat(index) * laneWidth, y: header)
        }
        ForEach(timeline.ticks.indices, id: \.self) { index in
          let tick = timeline.ticks[index]
          let y = top + timeline.fraction(tick) * height
          Rectangle().fill(Ink.tertiary.opacity(0.25)).frame(width: width, height: 1)
            .offset(x: gutter, y: y)
          Text(timeline.label(tick))
            .font(.system(size: context.size(10))).monospacedDigit().foregroundStyle(Ink.secondary)
            .lineLimit(1).frame(width: gutter - 7, height: 14, alignment: .trailing)
            .offset(y: y - 7)
        }
        if let marker = timeline.marker {
          let x = gutter + CGFloat(timeline.nowLane ?? 0) * laneWidth
          let y = top + timeline.fraction(marker) * height
          Rectangle().fill(Color.accentColor)
            .frame(width: timeline.nowLane == nil ? width : laneWidth, height: 1 / displayScale)
            .overlay(alignment: .leading) {
              Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -2)
            }
            .offset(x: x, y: y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        ForEach(timeline.spans.indices, id: \.self) { index in
          let span = timeline.spans[index]
          let placement = placements[index]
          let columnWidth = laneWidth / CGFloat(placement.columns)
          TimelineItem(
            item: span.item, lane: timeline.lanes[span.lane],
            width: max(1, columnWidth - 3), height: placement.height
          )
          .offset(
            x: gutter + CGFloat(span.lane) * laneWidth + CGFloat(placement.column) * columnWidth + 2,
            y: top + placement.top)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
    }
    .frame(height: context.size(250))
    .modifier(PageBox(selected: false))
  }
}

private struct TimelineItem: View {
  let item: PageItem
  let lane: String
  let width: CGFloat
  let height: CGFloat
  @Environment(\.page) private var context
  @Environment(\.pageSelection) private var selection

  var body: some View {
    let selected = item.target != nil && item.target == selection
    let shape = RoundedRectangle(cornerRadius: 4)
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 2) {
        if item.icon != nil, width >= 45 { PageIcon(item: item, size: context.size(11)) }
        Text(item.title ?? "").font(.system(size: context.size(10), weight: .medium))
          .lineLimit(1).allowsTightening(true).minimumScaleFactor(0.85)
      }
      if let subtitle = item.subtitle, height >= context.size(36), width >= 54 {
        Text(subtitle).font(.system(size: context.size(10))).foregroundStyle(Ink.secondary).lineLimit(1)
      }
    }
    .lineHeight(.multiple(factor: 1))
    .padding(.horizontal, width >= 18 ? 3 : 1)
    .padding(.top, context.size(1))
    .frame(width: width, height: height, alignment: .topLeading)
    .background {
      shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
      shape.fill(selected ? Ink.selection : Color.accentColor.opacity(0.18))
    }
    .overlay { shape.strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0.35), lineWidth: 0.5) }
    .clipShape(shape)
    .contentShape(.rect)
    .onTapGesture { if let target = item.target { context.click(target) } }
    .accessibilityElement()
    .accessibilityLabel(
      [item.title, item.subtitle, item.label, item.value, lane].compactMap { $0 }.joined(separator: ", ")
    )
    .accessibilityAddTraits(item.target == nil ? [] : selected ? [.isButton, .isSelected] : .isButton)
    .id(item.target)
  }
}
