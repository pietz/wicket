import Charts
import SwiftUI
import WicketCore

/// `<chart>`: bars, a line or a sparkline drawn with Swift Charts, its title above; Wicket picks
/// the scales, ticks and colors. VoiceOver reads its summary (`summary`) as well as its marks.
struct ChartView: ComponentView {
    let node: WicketCore.Chart
    @Environment(\.textSize) private var textSize

    init(_ node: WicketCore.Chart) { self.node = node }

    private var series: Bool { node.points.contains { $0.series != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * textSize.scale) {
            if node.title != nil || node.kind == .sparkline {
                HStack(alignment: .firstTextBaseline) {
                    if let title = node.title { Text(title).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 8)
                    if node.kind == .sparkline, let range = Self.range(node) { Text(range).monospacedDigit() }
                }
                .font(.system(size: textSize.points(11)))
                .foregroundStyle(.secondary)
            }
            chart
                .frame(height: (node.kind == .sparkline ? 36 : 140) * textSize.scale)
                .accessibilityLabel(node.title ?? "Chart")
                .accessibilityValue(Self.summary(node))
        }
    }

    @ViewBuilder private var chart: some View {
        let points = Array(node.points.enumerated())
        let unit = node.unit.map { "Value (\($0))" } ?? "Value"
        switch node.kind {
        case .bar:
            Charts.Chart(points, id: \.offset) { _, point in
                BarMark(x: .value("Label", point.label), y: .value(unit, point.value))
                    .foregroundStyle(by: .value("Series", point.series ?? ""))
                    .position(by: .value("Series", point.series ?? ""))
                    .cornerRadius(3)
            }
            .chartLegend(series ? .visible : .hidden)
            .chartForegroundStyleScale(range: Self.palette(series))
        case .line:
            Charts.Chart(points, id: \.offset) { _, point in
                LineMark(x: .value("Label", point.label), y: .value(unit, point.value))
                    .foregroundStyle(by: .value("Series", point.series ?? ""))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Label", point.label), y: .value(unit, point.value))
                    .foregroundStyle(by: .value("Series", point.series ?? ""))
                    .symbolSize(18)
            }
            .chartLegend(series ? .visible : .hidden)
            .chartForegroundStyleScale(range: Self.palette(series))
            .chartYScale(domain: .automatic(includesZero: false))
        case .sparkline:
            Charts.Chart(points, id: \.offset) { _, point in
                LineMark(x: .value("Label", point.label), y: .value(unit, point.value))
                    .foregroundStyle(by: .value("Series", point.series ?? ""))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartLegend(.hidden)
            .chartForegroundStyleScale(range: Self.palette(series))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    /// One series in the accent color; several in the system's distinct hues.
    private static func palette(_ series: Bool) -> [Color] {
        series ? [.blue, .orange, .green, .purple] : [.accentColor]
    }

    /// The lowest and highest values with the unit, as a sparkline's header says it: "7–10 °C".
    static func range(_ chart: WicketCore.Chart) -> String? {
        let values = chart.points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        let unit = chart.unit.map { " " + $0 } ?? ""
        return low == high ? "\(low.formatted())\(unit)" : "\(low.formatted())–\(high.formatted())\(unit)"
    }

    /// What VoiceOver says the chart shows: its kind, how many values and their extremes.
    static func summary(_ chart: WicketCore.Chart) -> String {
        let kind =
            switch chart.kind {
            case .bar: "Bar chart"
            case .line: "Line chart"
            case .sparkline: "Sparkline"
            }
        let unit = chart.unit.map { " " + $0 } ?? ""
        guard let low = chart.points.min(by: { $0.value < $1.value }),
            let high = chart.points.max(by: { $0.value < $1.value })
        else { return kind }
        let count = chart.points.count == 1 ? "1 value" : "\(chart.points.count) values"
        let series = Set(chart.points.compactMap(\.series)).count
        let groups = series > 1 ? " in \(series) series" : ""
        return "\(kind), \(count)\(groups): lowest \(low.value.formatted())\(unit) at \(low.label), "
            + "highest \(high.value.formatted())\(unit) at \(high.label)"
    }
}
