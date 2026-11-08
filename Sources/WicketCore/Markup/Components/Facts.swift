import Foundation

/// A table of labels and values: adjacent `<fact>`s, titled by `<facts>`.
public struct Facts: Component {
    public var title: String?
    public var facts: [Detail.Metadata]

    public static let tags = [
        Markup.Tag(
            "fact",
            [
                Markup.Attribute("label", required: true, "The name."),
                Markup.Attribute("value", required: true, "The value."),
            ], grouping: "Adjacent facts form a table of labels and values.",
            use: "A labelled value: a property, a date, a setting."),
        Markup.Tag(
            "facts", [.title], body: .tags(["fact"]), role: .wrapper,
            use: "Optional: titles a table of facts."),
    ]

    public static let example = (
        markup: """
        <fact label="Born" value="2 Sep 1964"/>
        <fact label="Birthplace" value="Beirut, Lebanon"/>
        """,
        text: "Born: 2 Sep 1964\nBirthplace: Beirut, Lebanon"
    )

    public static func make(_ build: Markup.Build) -> Facts? {
        Facts(facts: [Detail.Metadata(label: build.text("label")!, value: build.text("value")!)])
    }

    public func text(home: URL) -> String {
        ([title].compactMap { $0 } + facts.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }

    public func joining(_ next: Facts) -> Facts? {
        title == nil && next.title == nil ? Facts(facts: facts + next.facts) : nil
    }

    public func titled(_ title: String) -> Facts { Facts(title: title, facts: facts) }
}
