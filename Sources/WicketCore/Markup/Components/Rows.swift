import Foundation

/// A list of rows, as in a list screen: files, links and plain rows, adjacent ones joined, titled by
/// `<list>`. Each row is an `Item` whose subject derives its icon, folder, date and actions.
public struct Rows: Component {
    public var title: String?
    public var items: [Item]

    private static let grouping = "Adjacent rows (file, url, item) form a list."
    private static let fields = [
        Markup.Attribute("subtitle", "The second line."),
        Markup.Attribute("accessory", "A short text at the right."),
    ]

    public static let tags = [
        Markup.Tag(
            "file",
            [
                Markup.Attribute("path", .path, required: true, "An absolute or ~/ path, or a file: URL."),
                Markup.Attribute("title", "Defaults to the file's name."),
            ] + fields + [.icon("instead of the Finder icon")], focus: .always, grouping: grouping,
            use: "A file or folder to open, reveal or copy; Wicket adds its icon, folder and date."),
        Markup.Tag(
            "url", aliases: ["link"],
            [
                Markup.Attribute("href", .link, required: true, "An http, https or mailto link."),
                Markup.Attribute("title", "Defaults to the host."),
            ] + fields + [.icon("instead of the globe")], focus: .always, grouping: grouping,
            use: "A web page or mail address to open: sources, results, references."),
        Markup.Tag(
            "item",
            [Markup.Attribute("title", required: true, "The row's text.")] + fields + [
                .icon("at its left"), .href, .path,
                Markup.Attribute("copy", "Return copies this text (without a target: the title)."),
            ], focus: .always, icon: "doc.text", exclusive: ["href", "path", "copy"], grouping: grouping,
            use: "A plain row: a commit, a contact, a result that is neither a file nor a link."),
        Markup.Tag(
            "list", [.title], body: .tags(["file", "url", "item"]), role: .wrapper,
            use: "Optional: titles a list of rows."),
    ]

    public static let example = (
        markup: """
        <list title="Sources">
        <url href="https://en.wikipedia.org/wiki/Keanu_Reeves" title="Wikipedia"/>
        <item title="Commit a1c94e2" copy="a1c94e2"/>
        </list>
        """,
        text: "Sources\n- Wikipedia · https://en.wikipedia.org/wiki/Keanu_Reeves\n- Commit a1c94e2"
    )

    public static func make(_ build: Markup.Build) -> Rows? {
        let subject = build.target()
        let title = build.text("title")
        let copy =
            build.name == "item" && subject == nil
            ? [Item.Action.copy(text: build.text("copy") ?? title!)] : []
        let item = build.item(
            subject: subject, id: subject == nil ? "item:" + title! : nil, title: title,
            subtitle: build.text("subtitle"),
            icon: build.text("icon"), accessory: build.text("accessory"), actions: copy)
        return Rows(items: [item])
    }

    public func text(home: URL) -> String {
        ([title].compactMap { $0 } + items.map { "- " + $0.line(home: home) }).joined(separator: "\n")
    }

    public var targets: [Item] { items }

    public func joining(_ next: Rows) -> Rows? {
        title == nil && next.title == nil ? Rows(items: items + next.items) : nil
    }

    public func titled(_ title: String) -> Rows { Rows(title: title, items: items) }
}

extension Document {
    /// The document as a list, when it is only rows (in titled groups or not): such a reply keeps a
    /// list's behaviour, first row selected and typing to filter. Nil for anything else.
    public var listing: Listing? {
        let groups = blocks.compactMap { $0.component(Rows.self) }
        guard !groups.isEmpty, groups.count == blocks.count else { return nil }
        return Listing(sections: groups.map { Listing.Section(title: $0.title, items: $0.items) })
    }
}
