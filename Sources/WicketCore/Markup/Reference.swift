import Foundation

// The references generated from the registry: what the agent is told (its "Your reply" section in
// agent.md) and the component reference in docs/markup.md, which a test keeps equal to `reference()`.

extension Markup {
    /// The markup the agent may write, as Markdown for its instructions: the syntax rules, every tag
    /// with its attributes (required ones in bold) and when to use it, and the limits. Aliases are
    /// never listed, so the agent learns one spelling.
    public static func agentReference() -> String {
        let wrappers = catalog.filter { $0.role == .wrapper }.map { "`<\($0.name)>`" }
        let groups: String = catalog.compactMap(\.grouping).joined(separator: " ")
        var lines: [String] = [
            "Reply in Markdown. Where it helps the user see, compare or act on something, use Wicket's tags; Wicket draws them natively.",
            "",
            "- A tag starts its own line. Attributes are `name=\"value\"`. A tag closes itself (`<stat value=\"7\" label=\"Open\"/>`) or wraps content up to its closing tag (`<card title=\"…\">` … `</card>`).",
            "- Repeat a tag to make a group. \(groups) \(list(wrappers)) only add a `title` to their group.",
            "- Tables, emphasis, code and links in prose are Markdown. Files and pages the user may open belong in rows, not as paths in prose.",
            "- Only the tags and attributes below exist: anything else (HTML such as `<b>` or `<br>`, a misspelling) shows as text. Tags inside code blocks are code.",
            "",
            "| Tag | Attributes | Use when |",
            "|---|---|---|",
        ]
        for tag in catalog {
            let attributes: [String] = tag.attributes.map { attribute in
                let name = attribute.required ? "**\(attribute.name)**" : attribute.name
                guard case .choice(let choices) = attribute.type else { return name }
                return "\(name) (\(choices.joined(separator: ", ")))"
            }
            let use = [tag.use, tag.grouping].compactMap { $0 }.joined(separator: " ")
            let form = tag.body == .none ? "<\(tag.name)/>" : "<\(tag.name)>…</\(tag.name)>"
            lines.append("| `\(form)` | \(attributes.joined(separator: ", ")) | \(use) |")
        }
        let limits = limits().map { "\($0.what) \($0.value)" }.joined(separator: "; ")
        lines += ["", "Limits: \(limits)."]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The component reference for docs/markup.md: each component with an example and its Copy
    /// Answer text, then each of its tags with its attributes, content, grouping and selection; then
    /// the limits.
    public static func reference() -> String {
        var lines: [String] = []
        for component in components {
            let names = component.tags.map { "`<\($0.name)>`" }
            lines += ["### " + list(names), "", "```", component.example.markup, "```", ""]
            lines += ["Copy Answer copies:", "", "```", component.example.text, "```", ""]
            for tag in component.tags { lines += describe(tag) }
        }
        lines += ["### Limits", "", "| Limit | Value |", "|---|---|"]
        for limit in limits() {
            lines.append("| \(limit.what.prefix(1).uppercased())\(limit.what.dropFirst()) | \(limit.value) |")
        }
        lines += ["", "Past a limit the rest shows as text; the reply never fails."]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ tag: Tag) -> [String] {
        var about: [String] = ["**`<\(tag.name)>`**", tag.use]
        if let grouping = tag.grouping { about.append(grouping) }
        switch tag.body {
        case .none: about.append("Closes itself.")
        case .text: about.append("Wraps its text; a tag line ends it.")
        case .markdown: about.append("Wraps Markdown, without tags; a tag line ends it.")
        case .blocks: about.append("Wraps any blocks.")
        case .tags(let names):
            let held = list(names.map { "`<\($0)>`" })
            let rest = tag.role == .wrapper ? "is placed as if it weren't there" : "is ignored"
            about.append("Holds \(held); anything else in it \(rest).")
        }
        switch tag.focus {
        case .never: break
        case .always: about.append("The arrows select it.")
        case .withTarget: about.append("The arrows select it when it has an `href` or `path`.")
        }
        if !tag.exclusive.isEmpty {
            about.append("Takes one of " + list(tag.exclusive.map { "`\($0)`" }, "or") + ".")
        }
        if !tag.aliases.isEmpty {
            let aliases = list(tag.aliases.map { "`<\($0)>`" })
            about.append("Also read as \(aliases), which `wicket check` asks to spell `<\(tag.name)>`.")
        }
        var lines = [about.joined(separator: " "), ""]
        guard !tag.attributes.isEmpty else { return lines }
        lines += ["| Attribute | Value | Required | Meaning |", "|---|---|---|---|"]
        for attribute in tag.attributes {
            var meaning = attribute.summary
            if !attribute.aliases.isEmpty {
                meaning += " Also read as " + list(attribute.aliases.map { "`\($0)`" }) + "."
            }
            let required = attribute.required ? "yes" : ""
            lines.append("| `\(attribute.name)` | \(value(attribute.type)) | \(required) | \(meaning) |")
        }
        return lines + [""]
    }

    /// The document's limits and each tag's own count.
    private static func limits() -> [(what: String, value: String)] {
        var limits: [(what: String, value: String)] = [
            ("markup per screen", "\(Limits.bytes / 1024) KiB"), ("tags per document", "\(Limits.elements)"),
            ("columns and cards inside one another", "\(Limits.layoutDepth)"),
        ]
        for tag in catalog {
            if let limit = tag.limit { limits.append(("`<\(tag.name)>` per document", "\(limit)")) }
        }
        return limits
    }

    private static func value(_ type: ValueType) -> String {
        switch type {
        case .text: "text"
        case .number: "number"
        case .choice(let choices): choices.map { "`\($0)`" }.joined(separator: ", ")
        case .link: "http, https or mailto link"
        case .path: "absolute or `~/` path, or `file:` URL"
        case .source: "https URL or path"
        case .symbol: "SF Symbol name"
        }
    }

    /// "a, b and c".
    private static func list(_ items: [String], _ last: String = "and") -> String {
        guard items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " \(last) " + items.last!
    }
}
