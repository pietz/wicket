import Foundation

/// The second pass: the scanner's tree, held to the catalog's rules and limits, becomes a document.
/// It knows no tag by name: everything specific to a component is in the component's file, which it
/// reaches through `Markup.tags`. Every rule a tag breaks is an `Issue`, and the tag shows as its
/// text, its content is shown in place, or the attribute is dropped.
final class MarkupBuilder {
    struct Scope {
        /// Layout tags (columns, cards) around this point.
        var depth = 0
        /// The tags around this point, innermost last.
        var ancestors: [String] = []
        /// Inside a tag, where indentation is layout and is removed from the prose.
        var nested: Bool { !ancestors.isEmpty }
    }

    /// Prose and file facts already worked out, carried from one parse to the next of a growing text.
    struct Cache: Sendable {
        /// Runs of prose between tags, by their text (and whether nested), with their issues by line
        /// offset.
        fileprivate var prose: [String: Prose] = [:]
        /// Whether a file exists and its canonical id, which cost a trip to the disk.
        fileprivate var files: [URL: (id: String, exists: Bool)] = [:]
        /// Paths as written, read as files (nil if they aren't paths).
        fileprivate var paths: [String: Item.Subject?] = [:]
    }

    fileprivate struct Prose: Sendable {
        var chunks: [Document.Markdown]
        var issues: [(offset: Int, kind: Markup.Issue.Kind, message: String)]
    }

    private let bytes: [UInt8]
    let context: Markup.Context
    private let cache: Cache
    /// What this parse used of the cache or added to it: the next parse's cache.
    private(set) var used = Cache()
    private(set) var issues: [Markup.Issue] = []
    private var elements = 0
    private var counts: [String: Int] = [:]
    private var ids = Set<String>()

    init(bytes: [UInt8], context: Markup.Context, cache: Cache = Cache()) {
        self.bytes = bytes
        self.context = context
        self.cache = cache
    }

    /// `nodes` as blocks, adjacent groups joined.
    func blocks(_ nodes: [Markup.Node], _ scope: Scope) -> [Document.Block] {
        var blocks: [Document.Block] = []
        for node in nodes {
            let built: [Document.Block]
            switch node {
            case .text(let range, let line):
                built = prose(String(decoding: bytes[range], as: UTF8.self), line: line, scope)
                    .map { .markdown($0) }
            case .element(let element):
                built = build(element, scope)
            }
            for block in built {
                if case .component(let next) = block, case .component(let last)? = blocks.last,
                    let joined = last.joining(any: next)
                {
                    blocks[blocks.count - 1] = .component(joined)
                } else {
                    blocks.append(block)
                }
            }
        }
        return blocks
    }

    // MARK: Elements

    private func build(_ element: Markup.Element, _ scope: Scope) -> [Document.Block] {
        let (tag, component) = Markup.tags[element.written]!
        elements += 1
        if elements > Markup.Limits.elements {
            if elements == Markup.Limits.elements + 1 {
                issue(element, .limit, "more than \(Markup.Limits.elements) tags; the rest show as text")
            }
            return [literal(element)]
        }
        if element.written != tag.name {
            issue(element, .alias, "<\(element.written)> is read as <\(tag.name)>; write <\(tag.name)>")
        }
        if case .child(let parent) = tag.role {
            issue(element, .misplacedTag, "<\(tag.name)> belongs in <\(parent)>")
            return tag.body == .blocks ? blocks(element.children, scope) : [literal(element)]
        }
        guard let values = values(element, tag) else { return [literal(element)] }
        if context.placement == .summary, tag.focus == .always {
            issue(
                element, .misplacedTag, "<\(tag.name)> can't be in a summary, whose arrows belong to the rows"
            )
            return [literal(element)]
        }
        if let limit = tag.limit {
            counts[tag.name, default: 0] += 1
            if counts[tag.name]! > limit {
                issue(
                    element, .limit, "more than \(limit) <\(tag.name)> in one document; the rest show as text"
                )
                return [literal(element)]
            }
        }
        if tag.isLayout, scope.depth >= Markup.Limits.layoutDepth {
            issue(element, .misplacedTag, "<\(tag.name)> is nested too deep; its content is shown in place")
            return blocks(element.children, scope)
        }
        if !tag.nests, scope.ancestors.contains(tag.name) {
            issue(
                element, .misplacedTag,
                "<\(tag.name)> can't be inside <\(tag.name)>; its content is shown in place")
            return blocks(element.children, scope)
        }
        if tag.role == .wrapper {
            return wrapper(element, tag, component, title: values["title"], scope)
        }
        let build = Markup.Build(builder: self, element: element, tag: tag, values: values, scope: scope)
        guard let node = component.make(build) else { return [literal(element)] }
        return [.component(node)]
    }

    /// A wrapper's children, placed as if it weren't there; with a title, on the first group of its
    /// component, which then takes nothing after it.
    private func wrapper(
        _ element: Markup.Element, _ tag: Markup.Tag, _ component: any Component.Type, title: String?,
        _ scope: Scope
    ) -> [Document.Block] {
        if case .tags(let allowed) = tag.body {
            for case .element(let child) in element.children
            where !allowed.contains(Markup.tags[child.written]!.tag.name) {
                issue(child, .misplacedTag, "<\(child.written)> doesn't belong in <\(tag.name)>")
            }
        }
        var blocks = blocks(element.children, scope)
        if let title, let first = blocks.firstIndex(where: { $0.isComponent(component) }),
            case .component(let group) = blocks[first]
        {
            blocks[first] = .component(group.titled(any: title))
        }
        return blocks
    }

    // MARK: Attributes

    /// The element's attributes held to its tag: the ones it declares, valid, under their own names.
    /// Nil when a required one is missing or invalid, so the tag shows as text.
    func values(_ element: Markup.Element, _ tag: Markup.Tag) -> [String: String]? {
        var values: [String: String] = [:]
        for (written, value) in element.attributes {
            guard
                let attribute = tag.attributes.first(where: {
                    $0.name == written || $0.aliases.contains(written)
                })
            else {
                issue(
                    element, .unknownAttribute, "<\(tag.name)> has no attribute \"\(written)\"; it is ignored"
                )
                continue
            }
            if written != attribute.name {
                issue(
                    element, .alias,
                    "<\(tag.name)> reads \"\(written)\" as \"\(attribute.name)\"; write \(attribute.name)")
            }
            guard values[attribute.name] == nil else {
                issue(
                    element, .duplicateAttribute,
                    "<\(tag.name)> has \"\(attribute.name)\" twice; the first counts")
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let valid = validate(trimmed, attribute.type) else {
                issue(
                    element, .invalidValue,
                    "<\(tag.name)> \(attribute.name) \"\(trimmed)\" \(Self.expectation(attribute.type)); it is ignored"
                )
                continue
            }
            values[attribute.name] = valid
        }
        var taken: String?
        for name in tag.exclusive where values[name] != nil {
            if let taken {
                values[name] = nil
                issue(
                    element, .invalidValue,
                    "<\(tag.name)> takes \(taken) or \(name), not both; \(name) is ignored")
            }
            taken = taken ?? name
        }
        let missing = tag.attributes.filter { $0.required && values[$0.name] == nil }.map(\.name)
        guard missing.isEmpty else {
            issue(
                element, .missingAttribute,
                "<\(element.written)> needs \(missing.joined(separator: " and ")); it shows as text")
            return nil
        }
        return values
    }

    /// `value` as `type` wants it (a choice in lower case, a number in plain digits), nil if invalid.
    private func validate(_ value: String, _ type: Markup.ValueType) -> String? {
        switch type {
        case .text: value
        case .number: Self.number(value).map { String($0) }
        case .choice(let choices): choices.contains(value.lowercased()) ? value.lowercased() : nil
        case .link: Self.link(value) == nil ? nil : value
        case .path: file(value) == nil ? nil : value
        case .source: source(value) == nil ? nil : value
        case .symbol:
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            } ? value : nil
        }
    }

    private static func expectation(_ type: Markup.ValueType) -> String {
        switch type {
        case .text: "must be text"
        case .number: "must be a number"
        case .choice(let choices): "must be " + choices.joined(separator: ", ")
        case .link: "must be an http, https or mailto link"
        case .path: "must be an absolute or ~/ path, or a file: URL"
        case .source: "must be an https URL or a path"
        case .symbol: "must be an SF Symbol name, such as cloud.rain"
        }
    }

    /// A link Wicket follows: http, https or mailto.
    static func link(_ value: String) -> Item.Subject? {
        guard case .url(let url)? = Item.Subject.url(parsing: value),
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return .url(url)
    }

    /// A path as a file, nil if it isn't one.
    func file(_ value: String) -> Item.Subject? {
        let file =
            cache.paths[value] ?? used.paths[value] ?? Item.Subject.file(parsing: value, home: context.home)
        used.paths[value] = file
        return file
    }

    /// An image's source: an https URL with a host, or a path.
    func source(_ value: String) -> Item.Subject? {
        if let file = file(value) { return file }
        guard case .url(let url)? = Item.Subject.url(parsing: value), url.scheme?.lowercased() == "https",
            url.host() != nil
        else { return nil }
        return .url(url)
    }

    /// A number as people write it: `1,234.5`, `−3`, `40%`, `1 200`. Nil if it isn't one.
    static func number(_ text: String) -> Double? {
        var text = text.replacingOccurrences(of: "−", with: "-")
        text.removeAll { $0 == " " || $0 == "\u{202F}" || $0 == "\u{00A0}" || $0 == "_" || $0 == "%" }
        if text.contains(",") {
            let groups = text.split(separator: ",", omittingEmptySubsequences: false)
            let thousands = text.contains(".") || groups.dropFirst().allSatisfy { $0.count == 3 }
            text = text.replacingOccurrences(of: ",", with: thousands ? "" : ".")
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return number
    }

    // MARK: Items

    /// A selectable row about `subject`, deriving what it leaves out as a list's row would, with an id
    /// unique in the document (a reply can't be told its rows repeat, so a repeat gets `#2`).
    func item(
        subject: Item.Subject?, id: String?, title: String?, subtitle: String?, icon: Item.Icon?,
        accessory: String?, actions: [Item.Action], defaultIcon: String
    ) -> Item {
        var known: (id: String, exists: Bool)?
        if case .file(let url) = subject {
            let facts =
                cache.files[url] ?? used.files[url]
                ?? (subject!.id, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            used.files[url] = facts
            known = facts
        }
        var item = Item(
            subject: subject, id: id ?? known?.id, title: title, subtitle: subtitle, icon: icon,
            accessory: accessory, actions: actions, origin: context.origin, home: context.home,
            defaultIcon: .symbol(name: defaultIcon), exists: known?.exists)
        var unique = item.id
        var ordinal = 2
        while ids.contains(unique) {
            unique = "\(item.id)#\(ordinal)"
            ordinal += 1
        }
        ids.insert(unique)
        item.id = unique
        return item
    }

    // MARK: Prose

    /// Prose between tags as markdown. A run already parsed (the same text, at any line) is reused,
    /// with its issues, so a growing text reparses only what changed.
    func prose(_ text: String, line: Int, _ scope: Scope) -> [Document.Markdown] {
        let key = (scope.nested ? "n" : "t") + text
        let prose: Prose
        if let cached = cache.prose[key] ?? used.prose[key] {
            prose = cached
        } else {
            guard text.contains(where: { !$0.isWhitespace }) else { return [] }
            let text = scope.nested ? Self.dedented(text) : text
            let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let blocks = MarkdownBlock.parse(text)
            prose = Prose(
                chunks: blocks.isEmpty ? [] : [Document.Markdown(source: source, blocks: blocks)],
                issues: Self.inlineTags(text, indentedCode: !scope.nested))
        }
        used.prose[key] = prose
        issues += prose.issues.map {
            Markup.Issue(line: line + $0.offset, kind: $0.kind, message: $0.message)
        }
        return prose.chunks
    }

    /// Each `<name` in prose, by line offset: a Wicket tag that doesn't start a line, or a tag Wicket
    /// doesn't know (real HTML, a misspelling). Both show as text. Only opening tags count, and code
    /// is skipped: fences, code spans and, at the top level, indented code.
    private static func inlineTags(_ text: String, indentedCode: Bool)
        -> [(offset: Int, kind: Markup.Issue.Kind, message: String)]
    {
        guard text.contains("<") else { return [] }
        var found: [(offset: Int, kind: Markup.Issue.Kind, message: String)] = []
        var fenced = false
        var blank = true
        var indented = false
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            defer { blank = trimmed.isEmpty }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            indented = indentedCode && !trimmed.isEmpty && indent >= 4 && (blank || indented)
            guard !fenced, !indented, line.contains("<") else { continue }
            var code = false
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                index = line.index(after: index)
                if character == "`" { code.toggle() }
                guard !code, character == "<" else { continue }
                let name = line[index...]
                let letters = name.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                guard let first = letters.first, first.isLetter else { continue }
                let after = name.dropFirst(letters.count).first
                guard after == nil || after == ">" || after == "/" || after!.isWhitespace else { continue }
                let tag = letters.lowercased()
                found.append(
                    Markup.tags[tag] == nil
                        ? (offset, .unknownTag, "<\(tag)> isn't a Wicket tag; it shows as text")
                        : (offset, .misplacedTag, "<\(tag)> must start its own line; here it shows as text"))
            }
        }
        return found
    }

    /// `text` with the indentation its lines share removed: inside a tag, indentation is layout.
    static func dedented(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let indent =
            lines.filter { $0.contains { !$0.isWhitespace } }.map {
                $0.prefix { $0 == " " || $0 == "\t" }.count
            }
            .min() ?? 0
        guard indent > 0 else { return text }
        return lines.map { $0.contains { !$0.isWhitespace } ? String($0.dropFirst(indent)) : "" }
            .joined(separator: "\n")
    }

    // MARK: Text

    /// The text between an element's tags.
    func body(_ element: Markup.Element) -> String {
        var text = ""
        for case .text(let range, _) in element.children {
            text += String(decoding: bytes[range], as: UTF8.self)
        }
        return text
    }

    /// Whether a text node holds anything but whitespace.
    func isBlank(_ node: Markup.Node) -> Bool {
        guard case .text(let range, _) = node else { return false }
        return bytes[range].allSatisfy(\.isSpace)
    }

    /// The element as it was written, shown as text.
    func literal(_ element: Markup.Element) -> Document.Block {
        let source = String(decoding: bytes[element.start..<element.end], as: UTF8.self)
        return .text(source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func issue(_ element: Markup.Element, _ kind: Markup.Issue.Kind, _ message: String) {
        issues.append(.init(line: element.line, kind: kind, message: message))
    }
}

extension Document.Block {
    fileprivate func isComponent(_ type: any Component.Type) -> Bool {
        if case .component(let component) = self { Swift.type(of: component) == type } else { false }
    }
}

extension Component {
    fileprivate func titled(any title: String) -> any Component { titled(title) }
}
