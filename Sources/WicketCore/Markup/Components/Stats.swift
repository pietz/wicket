import Foundation

/// A strip of numbers worth seeing at a glance: adjacent `<stat>`s, titled by `<stats>`.
public struct Stats: Component {
    public struct Stat: Sendable, Hashable {
        public var value: String
        public var label: String?
        public var detail: String?
        /// An SF Symbol name; the view draws none when it can't draw it.
        public var icon: String?
        public var tone: Document.Tone?
    }

    public var title: String?
    public var stats: [Stat]

    public static let tags = [
        Markup.Tag(
            "stat",
            [
                Markup.Attribute("value", required: true, "The number or short value."),
                Markup.Attribute("label", "What it is."), Markup.Attribute("detail", "A line under it."),
                .icon("beside it"), .tone("Colors the value: good, a caution, bad."),
            ], grouping: "Adjacent stats form a strip, up to four per line.",
            use: "A number worth seeing at a glance."),
        Markup.Tag(
            "stats", [.title], body: .tags(["stat"]), role: .wrapper,
            use: "Optional: titles a strip of stats."),
    ]

    public static let example = (
        markup: """
        <stats title="Today">
        <stat value="12" label="Files"/>
        <stat value="+340" label="Added" tone="positive"/>
        </stats>
        """,
        text: "Today\nFiles: 12\nAdded: +340"
    )

    public static func make(_ build: Markup.Build) -> Stats? {
        Stats(stats: [
            Stat(
                value: build.text("value")!, label: build.text("label"), detail: build.text("detail"),
                icon: build.text("icon"), tone: build.tone())
        ])
    }

    public func text(home: URL) -> String {
        let lines = stats.map { stat in
            Document.line(stat.label.map { "\($0): \(stat.value)" } ?? stat.value, stat.detail)
        }
        return ([title].compactMap { $0 } + lines).joined(separator: "\n")
    }

    public func joining(_ next: Stats) -> Stats? {
        title == nil && next.title == nil ? Stats(stats: stats + next.stats) : nil
    }

    public func titled(_ title: String) -> Stats { Stats(title: title, stats: stats) }
}
