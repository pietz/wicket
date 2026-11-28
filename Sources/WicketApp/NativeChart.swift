import Charts
import SwiftUI

/// A `<chart>` in Swift Charts, from the values `Chart` parsed and checked: bars, a share of a whole, or
/// series (lines, areas, columns) with rules. Falls back to its data table.
struct NativeChart: View {
  let chart: Chart
  let pending: Bool
  @Environment(\.page) private var context
  @Environment(\.colorScheme) private var scheme
  /// The chart's own width, which is less than the page's in columns.
  @State private var width: CGFloat?

  var body: some View {
    VStack(alignment: .leading, spacing: context.size(8)) {
      if !chart.title.isEmpty {
        Text(chart.title).font(.system(size: context.size(PageMetrics.titleSize), weight: .semibold))
          .lineLimit(
            1)
      }
      if pending {
        VStack(spacing: 0) {
          ForEach(0..<4, id: \.self) { _ in
            Spacer(minLength: 0)
            Rectangle().fill(.separator).frame(height: 1)
          }
        }
        .accessibilityHidden(true)
      } else if !chart.invalid, chart.bars {
        bars
      } else if !chart.invalid, chart.shares, chart.marks.contains(where: { ($0.value ?? 0) > 0 }) {
        shares
      } else if !chart.invalid, chart.plot {
        plot
        if namedSeries.count >= 2 { legend(namedSeries) }
      } else {
        fallback
      }
    }
    // A plot, or its placeholder, fills the chart's height with its title and legend;
    // bars and shares are as tall as they are.
    .frame(height: fillsHeight ? context.size(PageMetrics.chartHeight) : nil, alignment: .top)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .font(.system(size: context.size(PageMetrics.smallSize)))
    .monospacedDigit()
  }

  private var fillsHeight: Bool { pending || !chart.invalid && chart.plot }

  /// The accent and four system colours, skipping its own family to distinguish adjacent series.
  private var palette: [Color] {
    let family = Ink.accentFamily()
    let skipped: Color? = ["3": .green, "5": .purple, "1": .orange, "6": .pink, "0": .pink][family]
    let rest: [Color] =
      [Color.green, .purple, .orange, .pink].filter { $0 != skipped } + (skipped == nil ? [] : [.blue])
    return [.accentColor] + rest
  }
  private func color(_ index: Int) -> Color { palette[index % palette.count] }
  private var lineWidth: CGFloat { scheme == .light ? 2.5 : 2 }

  /// Horizontal bars as rows of a grid: the label, the bar from zero, and its value at the bar's end.
  private var bars: some View {
    let values = chart.marks.map { $0.value ?? 0 }
    let chosen = chart.highlighted(values)
    let largest = max(values.map(abs).max() ?? 0, .leastNonzeroMagnitude)
    let low = min(0, (values.min() ?? 0) / largest)
    let high = max(0, (values.max() ?? 0) / largest)
    let span = high > low ? high - low : 1
    let room = context.size(
      CGFloat(values.map { chart.withUnit(Chart.compact($0)).count }.max() ?? 0) * 8 + 8)
    return Grid(alignment: .leading, horizontalSpacing: context.size(14), verticalSpacing: context.size(7)) {
      ForEach(chart.marks.indices, id: \.self) { index in
        GridRow {
          Text(chart.marks[index].label).font(context.body).lineLimit(1)
            .frame(maxWidth: context.size(220), alignment: .leading).fixedSize(
              horizontal: true, vertical: false)
          GeometryReader { geometry in
            let width = max(0, geometry.size.width - room * (low < 0 ? 2 : 1))
            let zero = (low < 0 ? room : 0) + width * CGFloat(-low / span)
            let end = (low < 0 ? room : 0) + width * CGFloat((values[index] / largest - low) / span)
            ZStack(alignment: .leading) {
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(chosen.map { $0 == index ? color(0) : Ink.chartNeutral } ?? color(0))
                .frame(width: abs(end - zero), height: context.size(14))
                .offset(x: min(zero, end))
              Text(chart.withUnit(Chart.compact(values[index]))).foregroundStyle(Ink.secondary).fixedSize()
                .frame(width: room - 6, alignment: values[index] < 0 ? .trailing : .leading)
                .offset(x: values[index] < 0 ? end - room : end + 6)
            }
            .frame(maxHeight: .infinity)
          }
          .frame(height: context.size(20))
        }
        .accessibilityElement(children: .combine)
      }
    }
    .accessibilityLabel(description("Bar chart comparing \(chart.marks.count) values"))
  }

  private var shares: some View {
    let parts = chart.marks.indices.map(String.init)
    return VStack(alignment: .leading, spacing: context.size(10)) {
      Charts.Chart {
        ForEach(chart.marks.indices, id: \.self) { index in
          BarMark(x: .value("Share", max(0, chart.marks[index].value ?? 0)), stacking: .normalized)
            .foregroundStyle(by: .value("Part", parts[index]))
            .clipShape(.rect(cornerRadius: 3))
        }
      }
      .chartForegroundStyleScale(domain: parts, range: parts.indices.map(color))
      .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
      .frame(height: 18)
      .accessibilityHidden(true)
      legend(
        chart.marks.enumerated().map { ($0.offset, $0.element.label) },
        values: chart.marks.map { chart.withUnit(Chart.compact($0.value ?? 0)) })
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(description("Share chart showing \(chart.marks.count) parts of a whole"))
  }

  /// The series' names under the plot, or the shares' with their values: a dot in each one's colour and
  /// the name in ink.
  private func legend(_ entries: [(color: Int, name: String)], values: [String]? = nil) -> some View {
    PageFlow(spacing: context.size(16)) {
      ForEach(entries.indices, id: \.self) { index in
        HStack(spacing: 5) {
          Circle().fill(color(entries[index].color)).frame(width: 7, height: 7).accessibilityHidden(true)
          Text(entries[index].name)
          if let values { Text(values[index]).foregroundStyle(Ink.secondary) }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .accessibilityHidden(values == nil)
  }

  /// Named series keep their plot colours in the legend; an unnamed one is simply left out.
  private var namedSeries: [(color: Int, name: String)] {
    chart.series.enumerated().filter { !$0.element.label.isEmpty }.map { ($0.offset, $0.element.label) }
  }

  /// A gap in a series starts a new segment, so a line never bridges it.
  private struct Point: Identifiable {
    let id: Int
    let series: Int
    let segment: String
    let category: Int
    let ordinal: Int
    let value: Double
    let low: Double
  }

  private var points: [Point] {
    var points: [Point] = []
    var stacks: [String: [Double]] = [:]
    for (index, mark) in chart.series.enumerated() {
      var segment = 0
      var ordinal = 0
      for (category, number) in mark.points.prefix(chart.labels.count).enumerated() {
        guard let value = number?.value else {
          segment += 1
          continue
        }
        var low = 0.0
        if mark.kind == .column, let stack = mark.stack {
          var base = stacks[stack] ?? Array(repeating: 0, count: chart.labels.count)
          low = base[category]
          base[category] += value
          stacks[stack] = base
        }
        points.append(
          Point(
            id: points.count, series: index, segment: "\(index)-\(segment)", category: category,
            ordinal: ordinal,
            value: value, low: low))
        ordinal += 1
      }
    }
    return points
  }

  private var plot: some View {
    let series = chart.series
    let names = series.enumerated().map { chart.seriesName($0.element, $0.offset) }
    let columns = series.indices.filter { series[$0].kind == .column }
    let chosen =
      columns.count == 1 ? chart.highlighted(points.filter { $0.series == columns[0] }.map(\.value)) : nil
    let rules = chart.marks.filter { $0.kind == .rule }
    let points = self.points
    let shown = Set(shownCategories)
    let categories = chart.labels.indices.map(String.init)
    let segmentCounts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
    // A reading between two gaps has no line to draw, so it shows as a dot.
    @ViewBuilder func singleton(_ point: Point) -> some View {
      if segmentCounts[point.segment] == 1 { Circle().fill(color(point.series)).frame(width: 6) }
    }
    let narrow = plotWidth < 300
    let groupsBySeries = series.indices.map { series[$0].stack.map { "stack:" + $0 } ?? "series:\($0)" }
    // As wide as the web's columns: at most 9% of the plot, sharing 78% of a category with its group.
    let groups = CGFloat(max(1, Set(columns.map { groupsBySeries[$0] }).count))
    let columnWidth =
      plotWidth * min(0.09, 0.78 / CGFloat(max(1, chart.labels.count)) / groups) * 0.84
    return Charts.Chart {
      ForEach(points) { point in
        let mark = series[point.series]
        let x = PlottableValue.value("Category", categories[point.category])
        switch mark.kind {
        case .column:
          BarMark(
            x: x, yStart: .value("Low", point.low),
            yEnd: .value(names[point.series], point.low + point.value), width: .fixed(columnWidth)
          )
          .position(by: .value("Group", groupsBySeries[point.series]))
          .clipShape(.rect(cornerRadius: 3))
          .accessibilityLabel(chart.labels[point.category])
          .accessibilityValue(chart.withUnit(Chart.compact(point.value)))
          .foregroundStyle(
            chosen.map { $0 == point.ordinal ? color(0) : Ink.chartNeutral } ?? color(point.series))
        case .area:
          // Each area fills from zero, as its outline shows; Swift Charts would stack them.
          AreaMark(
            x: x, y: .value(names[point.series], point.value),
            series: .value("Segment", point.segment), stacking: .unstacked
          )
          .foregroundStyle(
            LinearGradient(
              colors: [color(point.series).opacity(0.33), color(point.series).opacity(0)], startPoint: .top,
              endPoint: .bottom))
          LineMark(
            x: x, y: .value(names[point.series], point.value),
            series: .value("Segment", point.segment)
          )
          .foregroundStyle(color(point.series))
          .accessibilityLabel(chart.labels[point.category])
          .accessibilityValue(chart.withUnit(Chart.compact(point.value)))
          .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
          .symbol { singleton(point) }
        default:
          LineMark(
            x: x, y: .value(names[point.series], point.value),
            series: .value("Segment", point.segment)
          )
          .foregroundStyle(color(point.series))
          .accessibilityLabel(chart.labels[point.category])
          .accessibilityValue(chart.withUnit(Chart.compact(point.value)))
          .lineStyle(
            StrokeStyle(
              lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
              dash: mark.style == "dashed" ? [4, 4] : [])
          )
          .symbol { singleton(point) }
        }
      }
      ForEach(rules.indices, id: \.self) { index in
        let rule = rules[index]
        let tone = Ink.tone(rule.tone) ?? Ink.secondary
        if let at = rule.at, let index = chart.labels.firstIndex(of: at) {
          RuleMark(x: .value("Category", categories[index]))
            .foregroundStyle(tone).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(position: .top, alignment: .leading) { ruleLabel(rule.label) }
        } else if let value = rule.value {
          RuleMark(y: .value("Rule", value))
            .foregroundStyle(tone).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(position: .top, alignment: .trailing) { ruleLabel(rule.label) }
        }
      }
    }
    .chartXScale(domain: categories)
    .chartXAxis {
      AxisMarks { value in
        // Each label centres under its point, but the first starts at its point and the last ends at its
        // own, as on the web, so neither overhangs the plot. The axis ignores a label's anchor, so the
        // label is shifted over a hidden copy that keeps its place. Collisions are left to `shownCategories`,
        // which keeps the first and last.
        if let ordinal = value.as(String.self).flatMap(Int.init), shown.contains(ordinal) {
          let label = chart.labels[ordinal]
          let edge: HorizontalAlignment? =
            chart.labels.count < 2
            ? nil : ordinal == 0 ? .leading : ordinal == chart.labels.count - 1 ? .trailing : nil
          AxisValueLabel(collisionResolution: .disabled) {
            Text(label).font(context.small).hidden().overlay {
              Text(label).font(context.small).foregroundStyle(Ink.secondary).fixedSize()
                .alignmentGuide(HorizontalAlignment.center) { $0[edge ?? HorizontalAlignment.center] }
            }
          }
        }
      }
    }
    .chartYAxis {
      // The values on the leading edge, as a reader looks for them and the web draws them.
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        AxisValueLabel {
          let number = value.as(Double.self).map(Chart.compact) ?? ""
          Text(narrow && value.index == 0 ? chart.withUnit(number) : number)
            .font(context.small).foregroundStyle(Ink.secondary)
        }
      }
    }
    .chartYAxisLabel(position: .top, alignment: .trailing) {
      if !narrow, !chart.unit.isEmpty { Text(chart.unit).font(context.small).foregroundStyle(Ink.secondary) }
    }
    .chartLegend(.hidden)
    .accessibilityLabel(
      description("Chart of \(series.count) data series across \(chart.labels.count) categories"))
  }

  /// The category labels drawn: the first, the last, and evenly spaced ones between that fit the width.
  private var shownCategories: [Int] {
    let labels = chart.labels
    guard labels.count > 2 else { return Array(labels.indices) }
    // Points sit at band centres. The first label runs a full width right of its point and the last a
    // full width left of its own; those between are centred, every `step` from the first.
    let width = CGFloat(labels.map(\.count).max() ?? 1) * context.size(7)
    let gap = context.size(12)
    let slot = plotWidth / CGFloat(labels.count)
    let step = max(1, Int(((1.5 * width + gap) / slot).rounded(.up)))
    let last = labels.count - 1
    let between = stride(from: step, to: last, by: step).filter {
      CGFloat(last - $0) * slot >= 1.5 * width + gap
    }
    return [0] + between + [last]
  }

  /// About the plot's width: the chart's, less the values on the leading edge.
  private var plotWidth: CGFloat { max(1, (width ?? context.width - 40) - context.size(32)) }

  private func ruleLabel(_ label: String) -> some View {
    Text(label).foregroundStyle(Ink.secondary).lineLimit(1)
  }

  private func description(_ summary: String) -> String {
    [chart.title, summary + (chart.unit.isEmpty ? "" : " in " + chart.unit)].filter { !$0.isEmpty }
      .joined(separator: " — ")
  }

  /// The chart as a table, for one that cannot be drawn.
  private var fallback: some View {
    let series = chart.series
    let count = max(chart.labels.count, series.map(\.points.count).max() ?? 0)
    let items = chart.marks.filter { !$0.kind.isSeries }
    return Grid(alignment: .leading, horizontalSpacing: context.size(24), verticalSpacing: context.size(4)) {
      GridRow {
        Text(series.isEmpty ? "Label" : "Category")
        if series.isEmpty {
          Text("Value")
        } else {
          ForEach(series.indices, id: \.self) { Text(chart.seriesName(series[$0], $0)) }
        }
      }
      .fontWeight(.medium).foregroundStyle(Ink.secondary)
      Rectangle().fill(.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
      ForEach(0..<(series.isEmpty ? 0 : count), id: \.self) { index in
        GridRow {
          Text(
            index < chart.labels.count && !chart.labels[index].isEmpty
              ? chart.labels[index] : String(index + 1))
          ForEach(series.indices, id: \.self) { column in
            let points = series[column].points
            Text(index < points.count ? points[index].map { chart.withUnit($0.text) } ?? "" : "")
          }
        }
      }
      ForEach(items.indices, id: \.self) { index in
        GridRow {
          Text(items[index].label.isEmpty ? items[index].kind.rawValue.capitalized : items[index].label)
          Text(
            items[index].points.first.flatMap { $0 }.map { chart.withUnit($0.text) } ?? items[index].at ?? "")
        }
      }
    }
    .font(context.body)
    .textSelection(.enabled)
  }
}
