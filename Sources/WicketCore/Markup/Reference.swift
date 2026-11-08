import Foundation

// The references generated from the registry: what the agent is told (appended to the "Your reply"
// section that ends the bundled agent.md) and the component reference in docs/markup.md, which a
// test keeps equal to `reference()`.

extension Markup {
    /// The markup the agent may write, as Markdown for its instructions: the syntax rules, every tag
    /// with its attributes (required ones in bold) and when to use it, and the limits. Aliases are
    /// never listed, so the agent learns one spelling.
    public static func agentReference() -> String {
        let wrappers = catalog.filter { $0.role == .wrapper }.map { "`<\($0.name)>`" }
        var groups: [String] = []
        for grouping in catalog.compactMap(\.grouping) where !groups.contains(grouping) {
            groups.append(grouping)
        }
        var lines: [String] = [
            "Wicket draws the tags below natively, and they beat Markdown wherever content has structure, so "
                + "turn structure into tags:",
            "",
            "- Key numbers: `<stat>`s, with `tone` for good or bad.",
            "- Two or three things compared: a `<card>` each in `<columns>`, with stats or facts inside. A "
                + "Markdown table only for many rows or attributes.",
            "- Facts about one subject (specs, settings, a forecast): `<fact>`s.",
            "- Files and folders: `<file>` rows with absolute paths, never paths in prose. Sources and pages: `<url>` "
                + "rows. Other things to open or pick: `<item>` rows.",
            "- What changed (commits, edits), a day's events, history: a `<timeline>` of `<event>`s with times. A series of numbers: a `<chart>`. "
                + "Status: `<badge>`s. How full or far along: `<progress>`. A warning or tip: a `<callout>`.",
            "- Plain Markdown stays for an explanation, a how-to with code and a conversational reply. A "
                + "question whose answer is one value (a name, a number, a time) gets `<answer>` alone.",
            "",
            "For example:",
            "",
            "```",
            "<answer value=\"Pixel 11\" detail=\"Cheaper, longer battery\"/>",
            "<columns>",
            "<card title=\"iPhone 17\">",
            "<stat value=\"$799\" label=\"From\"/>",
            "<fact label=\"Battery\" value=\"22 h video\"/>",
            "</card>",
            "<card title=\"Pixel 11\">",
            "<stat value=\"$749\" label=\"From\" tone=\"positive\"/>",
            "<fact label=\"Battery\" value=\"26 h video\"/>",
            "</card>",
            "</columns>",
            "```",
            "",
            "Syntax:",
            "",
            "- A tag starts its own line. Attributes are `name=\"value\"`. A tag closes itself (`<stat value=\"7\" label=\"Open\"/>`) or wraps content up to its closing tag (`<card title=\"…\">` … `</card>`).",
            "- Repeat a tag to make a group. \(groups.joined(separator: " ")) \(list(wrappers)) only add a `title` to their group.",
            "- Tables, emphasis, code and links in prose are Markdown.",
            "- Only the tags and attributes below exist: anything else (HTML such as `<b>` or `<br>`, a misspelling) shows as text, so a placeholder such as `<name>` goes in backticks. Tags inside code blocks are code.",
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
            let form = tag.body == .none ? "<\(tag.name)/>" : "<\(tag.name)>…</\(tag.name)>"
            lines.append("| `\(form)` | \(attributes.joined(separator: ", ")) | \(tag.use) |")
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
        lines += [
            "",
            "Past a count limit the rest shows as text, and past the size limit the page stops (Copy keeps everything); the reply never fails.",
        ]
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
            about.append("Also read as \(aliases), which `wicket run` asks to spell `<\(tag.name)>`.")
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
