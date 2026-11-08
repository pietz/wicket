import Foundation

/// How far along something is: a bar with its amount.
public struct Progress: Component {
    public var value: Double
    public var max: Double
    public var label: String?
    public var tone: Document.Tone?

    /// How full the bar is, from 0 to 1.
    public var fraction: Double { Swift.min(Swift.max(value / max, 0), 1) }

    public static let tags = [
        Markup.Tag(
            "progress",
            [
                Markup.Attribute("value", .number, required: true, "How far."),
                Markup.Attribute(
                    "max", .number,
                    "The whole; without it, a value up to 1 is a fraction and more a percentage."),
                Markup.Attribute("label", "What is progressing."), .tone("Colors the bar."),
            ], use: "How far along something is.")
    ]

    public static let example = (
        markup: #"<progress label="Converted" value="18" max="24"/>"#,
        text: "Converted: 18 of 24"
    )

    public static func make(_ build: Markup.Build) -> Progress? {
        let value = build.number("value")!
        let max = build.number("max").flatMap { $0 > 0 ? $0 : nil } ?? (value <= 1 ? 1 : 100)
        return Progress(value: value, max: max, label: build.text("label"), tone: build.tone())
    }

    public func text(home: URL) -> String {
        let amount =
            max == 100 ? "\(Document.number(value))%" : "\(Document.number(value)) of \(Document.number(max))"
        return label.map { "\($0): \(amount)" } ?? amount
    }
}
