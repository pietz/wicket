import Foundation

/// Numbers across categories or time, drawn with Swift Charts: one `<point>` per value, a series
/// per line or bar group. Wicket chooses scales, ticks and colors.
public struct Chart: Component {
    public enum Kind: String, Sendable, Hashable {
        case bar, line, sparkline
    }

    public struct Point: Sendable, Hashable {
        public var label: String
        public var value: Double
        public var series: String?
    }

    public var kind: Kind
    public var title: String?
    public var unit: String?
    public var points: [Point]

    public static let pointLimit = 200
    public static let seriesLimit = 4

    public static let tags = [
        Markup.Tag(
            "chart",
            [
                Markup.Attribute(
                    "kind", .choice(["bar", "line", "sparkline"]), aliases: ["type"],
                    "bar (the default), line or sparkline."),
                Markup.Attribute("title", "Above the chart."),
                Markup.Attribute("unit", "The values' unit, such as °C or €."),
            ], body: .tags(["point"]), icon: "chart.bar", limit: 10,
            use:
                "Numbers across categories or time: one `<point>` per value, up to \(pointLimit), in up to \(seriesLimit) series."
        ),
        Markup.Tag(
            "point",
            [
                Markup.Attribute("label", required: true, "The category or time."),
                Markup.Attribute("value", .number, required: true, "The number."),
                Markup.Attribute("series", "Which line or bar group it belongs to, when there are several."),
            ], role: .child(of: "chart"), use: "One value, inside `<chart>`."),
    ]

    public static let example = (
        markup: """
        <chart kind="line" title="Daily high" unit="°C">
        <point label="Mon" value="9"/><point label="Tue" value="8"/><point label="Wed" value="7"/>
        </chart>
        """,
        text: "Daily high\nMon: 9 °C\nTue: 8 °C\nWed: 7 °C"
    )

    public static func make(_ build: Markup.Build) -> Chart? {
        var points: [Point] = []
        var series: [String] = []
        var dropped = 0
        for point in build.children("point") {
            let name = point.text("series")
            if let name, !series.contains(name) {
                guard series.count < seriesLimit else {
                    dropped += 1
                    continue
                }
                series.append(name)
            }
            guard points.count < pointLimit else {
                dropped += 1
                continue
            }
            points.append(Point(label: point.text("label")!, value: point.number("value")!, series: name))
        }
        if dropped > 0 {
            build.issue(
                .limit, "\(dropped) points past \(pointLimit) points or \(seriesLimit) series are left out")
        }
        guard !points.isEmpty else {
            build.issue(.missingAttribute, "<chart> needs at least one <point label value>; it shows as text")
            return nil
        }
        return Chart(
            kind: build.text("kind").flatMap(Kind.init) ?? .bar, title: build.text("title"),
            unit: build.text("unit"),
            points: points)
    }

    public func text(home: URL) -> String {
        let unit = unit.map { " " + $0 } ?? ""
        let lines = points.map { point in
            "\(point.series.map { "\($0), " } ?? "")\(point.label): \(Document.number(point.value))\(unit)"
        }
        return ([title].compactMap { $0 } + lines).joined(separator: "\n")
    }
}
