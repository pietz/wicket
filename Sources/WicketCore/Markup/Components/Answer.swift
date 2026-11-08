import Foundation

/// One short answer to a direct question, shown large; Return copies it.
public struct Answer: Component {
    /// Its row: the value as title, the detail under it, Copy as its action.
    public var item: Item

    public static let tags = [
        Markup.Tag(
            "answer",
            [
                Markup.Attribute("value", required: true, "The answer, shown large; Return copies it."),
                Markup.Attribute("detail", "A line under it: the context or source."), .icon("beside it"),
            ], focus: .always, icon: "equal.circle", limit: 1,
            use: "One short answer to a direct question, first in the reply; one per reply.")
    ]

    public static let example = (
        markup: #"<answer value="62" detail="Keanu Reeves, born 2 September 1964"/>"#,
        text: "62\nKeanu Reeves, born 2 September 1964"
    )

    public static func make(_ build: Markup.Build) -> Answer? {
        let value = build.text("value")!
        return Answer(
            item: build.item(
                subject: nil, id: "answer", title: value, subtitle: build.text("detail"),
                icon: build.text("icon"),
                actions: [.copy(text: value)]))
    }

    public func text(home: URL) -> String {
        [item.title, item.subtitle].compactMap { $0 }.joined(separator: "\n")
    }

    public var targets: [Item] { [item] }
}
