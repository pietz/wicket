import Foundation

/// Wicket's markup: markdown plus a fixed catalog of block-level tags, which agents write in their
/// replies and extensions in their pages (docs/markup.md). Each component is one file in
/// `Markup/Components`, registered in `components` below; the parser, the agent's reference, the
/// docs, the lint used by `wicket check` and the tests all read the catalog from there, so a tag
/// that isn't registered is never advertised.
public enum Markup {
    /// Every component, in the order the references list them. Adding one is its file and a line here.
    public static let components: [any Component.Type] = [
        Answer.self, Stats.self, Facts.self, Rows.self, Callout.self, Columns.self, Card.self, Gallery.self,
        Chart.self, Timeline.self, Progress.self, Badges.self,
    ]

    /// Every tag, by name and by alias, with the component that reads it.
    static let tags: [String: (tag: Tag, component: any Component.Type)] = {
        var tags: [String: (tag: Tag, component: any Component.Type)] = [:]
        for component in components {
            for tag in component.tags {
                for name in [tag.name] + tag.aliases {
                    precondition(tags[name] == nil, "<\(name)> is registered twice")
                    tags[name] = (tag, component)
                }
            }
        }
        return tags
    }()

    /// Every tag, in catalog order.
    public static var catalog: [Tag] { components.flatMap { $0.tags } }

    /// The limits every document is held to; a component's own (images per document, points per
    /// chart) are in its file. Past one, what crosses it shows as text, the reply never fails, and
    /// the count is logged.
    public enum Limits {
        /// Markup parsed per screen; the rest shows as plain text.
        public static let bytes = 64 * 1024
        /// Plain text shown after `bytes`, before it is cut.
        public static let tailBytes = 64 * 1024
        /// Tags per document.
        public static let elements = 500
        /// Layout tags (columns, cards) inside one another.
        public static let layoutDepth = 2
    }
}

extension Markup {
    /// What an attribute's value must be. Anything else is dropped (and a required attribute that is
    /// dropped turns its tag into text).
    public enum ValueType: Sendable, Hashable {
        case text
        /// A finite number; thousands separators, a Unicode minus and a trailing `%` are tolerated.
        case number
        /// One of these words, in any case.
        case choice([String])
        /// A web or mail link: http, https or mailto.
        case link
        /// A file or folder: an absolute or `~/` path, or a `file:` URL.
        case path
        /// An image: an https URL or a path.
        case source
        /// An SF Symbol name, such as `cloud.rain`. One Wicket can't draw falls back to the tag's own.
        case symbol
    }

    public struct Attribute: Sendable, Hashable {
        public let name: String
        public let type: ValueType
        public let required: Bool
        /// Habitual spellings the parser accepts; never advertised, and an error in a lint.
        public let aliases: [String]
        public let summary: String

        public init(_ name: String, required: Bool = false, _ summary: String) {
            self.init(name, .text, required: required, summary)
        }

        public init(
            _ name: String, _ type: ValueType, required: Bool = false, aliases: [String] = [],
            _ summary: String
        ) {
            self.name = name
            self.type = type
            self.required = required
            self.aliases = aliases
            self.summary = summary
        }

        public static let title = Attribute("title", "A title above the group.")
        public static func icon(_ place: String) -> Attribute {
            Attribute("icon", .symbol, "An SF Symbol \(place).")
        }
        public static func tone(_ summary: String, _ tones: [String] = ["positive", "warning", "negative"])
            -> Attribute
        {
            Attribute("tone", .choice(tones), summary)
        }
        public static let href = Attribute("href", .link, "Return opens this link.")
        public static let path = Attribute("path", .path, "Return opens this file.")
    }

    /// What a tag holds between its opening and closing tag.
    public enum Body: Sendable, Hashable {
        /// Nothing: the tag closes itself (`<stat …/>`); a closing tag is optional.
        case none
        /// Plain text, without tags: a tag line ends it.
        case text
        /// Markdown, without tags: a tag line ends it.
        case markdown
        /// Any blocks, within the nesting limits.
        case blocks
        /// These tags. A wrapper places anything else beside them; a component ignores it.
        case tags([String])
    }

    /// What a tag is to its component.
    public enum Role: Sendable, Hashable {
        /// Built into the component's node by its `make`.
        case node
        /// Only titles the group its children form; untitled, it is as if it weren't there.
        case wrapper
        /// Read only by its parent's `make` (a chart's points, a column); anywhere else it is misplaced.
        case child(of: String)
    }

    /// Whether the arrows can select a tag's block.
    public enum Focus: Sendable, Hashable {
        case never
        case always
        /// Only with a target: an `href` or a `path`.
        case withTarget
    }

    public struct Tag: Sendable, Hashable {
        public let name: String
        /// Habitual spellings (`<img>`), read as this tag; never advertised, and an error in a lint.
        public let aliases: [String]
        public let attributes: [Attribute]
        public let body: Body
        public let role: Role
        public let focus: Focus
        /// The SF Symbol drawn when the tag shows one and none (or one Wicket can't draw) is given.
        public let icon: String?
        /// When to use it, in one line: the agent's reference and the docs say this.
        public let use: String
        /// What repeating it makes, if it groups.
        public let grouping: String?
        /// Of these attributes at most one is used, the first given in this order.
        public let exclusive: [String]
        /// Counts toward `Limits.layoutDepth` (columns, cards).
        public let isLayout: Bool
        /// Whether it may sit inside another of itself (columns may not).
        public let nests: Bool
        /// How many a document may hold; later ones show as text.
        public let limit: Int?

        public init(
            _ name: String, aliases: [String] = [], _ attributes: [Attribute] = [], body: Body = .none,
            role: Role = .node, focus: Focus = .never, icon: String? = nil, exclusive: [String] = [],
            layout: Bool = false, nests: Bool = true, limit: Int? = nil, grouping: String? = nil, use: String
        ) {
            self.name = name
            self.aliases = aliases
            self.attributes = attributes
            self.body = body
            self.role = role
            self.focus = focus
            self.icon = icon
            self.use = use
            self.grouping = grouping
            self.exclusive = exclusive
            isLayout = layout
            self.nests = nests
            self.limit = limit
        }

        public func attribute(_ name: String) -> Attribute? { attributes.first { $0.name == name } }
    }
}
