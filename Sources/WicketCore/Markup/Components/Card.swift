import Foundation

/// Blocks about one subject on a quiet inset surface, with a heading. With an `href` or `path` the
/// whole card is one target: Return opens it.
public struct Card: Component {
    public var title: String?
    public var subtitle: String?
    /// An SF Symbol name; the view draws none when it can't draw it.
    public var icon: String?
    /// What Return opens when the card is selected; nil for a card the arrows skip.
    public var target: Item?
    public var blocks: [Document.Block]

    public static let tags = [
        Markup.Tag(
            "card",
            [
                Markup.Attribute("title", "Its heading."),
                Markup.Attribute("subtitle", "A line under the heading."),
                .icon("beside the heading"), .href, .path,
            ], body: .blocks, focus: .withTarget, exclusive: ["href", "path"], layout: true,
            use: "Groups blocks about one subject, such as each side of a comparison.")
    ]

    public static let example = (
        markup: """
        <card title="Pixel 11" href="https://store.google.com/product/pixel_11">
        <stat value="$749" label="From"/>
        </card>
        """,
        text: "Pixel 11 · https://store.google.com/product/pixel_11\nFrom: $749"
    )

    public static func make(_ build: Markup.Build) -> Card? {
        let title = build.text("title")
        let subtitle = build.text("subtitle")
        return Card(
            title: title, subtitle: subtitle, icon: build.text("icon"),
            target: build.target().map { build.item(subject: $0, title: title, subtitle: subtitle) },
            blocks: build.blocks())
    }

    public func text(home: URL) -> String {
        let heading = Document.line(title, subtitle, target?.subject?.location(home: home))
        return [heading, Document.text(blocks, home: home)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var targets: [Item] { [target].compactMap { $0 } + Document.targets(blocks) }
}
