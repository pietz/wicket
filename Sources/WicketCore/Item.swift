import Foundation

/// What the user has typed, numbered so late results for an older query can be told apart.
public struct Query: Codable, Sendable, Hashable {
    public var text: String
    /// Increases with every new query; results carry it back so stale ones are dropped.
    public var revision: Int

    public init(text: String, revision: Int) {
        self.text = text
        self.revision = revision
    }
}

/// One result row, from any source. Extensions send the same shape: its `Decodable` conformance is
/// the wire format of docs/extensions.md.
public struct Item: Sendable, Hashable, Identifiable {
    public enum Icon: Sendable, Hashable {
        /// The Finder icon of a file, folder or app.
        case file(url: URL)
        case symbol(name: String)
    }

    /// Each action can carry a title for the action panel; without one the palette names it.
    public enum Action: Sendable, Hashable {
        /// Opens a file, folder, app or web URL.
        case open(url: URL, title: String? = nil)
        case copy(text: String, title: String? = nil)
        /// Types the text into the app the user came from.
        case paste(text: String, title: String? = nil)
        /// Pushes a detail view; its title names the action.
        case detail(Detail)
        /// Runs a command of the extension the item came from, with `args` passed through.
        case run(command: String, args: [String: JSONValue]? = nil, title: String? = nil)
        /// Runs one of Wicket's built-in commands. Host only: extensions can't send it.
        case command(id: String)

        /// The title the source gave, if any.
        public var title: String? {
            switch self {
            case .open(_, let title), .copy(_, let title), .paste(_, let title), .run(_, _, let title): title
            case .detail(let detail): detail.title
            case .command: nil
            }
        }
    }

    /// Ranking tiers owned by the host, best first. Sources pick a tier; the score orders within it.
    public enum Relevance: String, Codable, Sendable, Hashable, Comparable {
        /// The query is exactly the title or an alias.
        case exact
        /// A computed answer to the query, such as a calculation.
        case answer
        /// A normal fuzzy match.
        case match
        /// Offered whatever was typed, such as asking an AI.
        case fallback

        public static func < (a: Relevance, b: Relevance) -> Bool { a.order < b.order }

        private var order: Int {
            switch self {
            case .exact: 0
            case .answer: 1
            case .match: 2
            case .fallback: 3
            }
        }
    }

    /// Namespaced by source and stable across launches ("apps:/Applications/Safari.app"); frecency
    /// and the selection follow it. Extension items arrive with their own id (or their title).
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var accessory: String?
    public var relevance: Relevance
    /// Orders items within a relevance tier; `SearchIndex` uses the fuzzy-matcher score. Host only.
    public var score: Double
    /// The first action is the primary one, run by Return.
    public var actions: [Action]

    public init(
        id: String, title: String, subtitle: String? = nil, icon: Icon, accessory: String? = nil,
        relevance: Relevance = .match, score: Double = 0, actions: [Action]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory
        self.relevance = relevance
        self.score = score
        self.actions = actions
    }
}

/// A markdown page with optional metadata and actions: a detail result, or a `detail` action.
public struct Detail: Sendable, Hashable, Decodable {
    public struct Metadata: Sendable, Hashable, Decodable {
        public var label: String
        public var value: String

        public init(from decoder: any Decoder) throws {
            let object = try decoder.object(["label", "value"])
            label = try object.required("label")
            value = try object.required("value")
        }
    }

    public var title: String?
    public var markdown: String
    public var metadata: [Metadata]
    public var actions: [Item.Action]

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["title", "markdown", "metadata", "actions"])
        title = try object.optional("title")
        markdown = try object.required("markdown")
        metadata = try object.optional("metadata") ?? []
        actions = try object.optional("actions") ?? []
    }
}

// MARK: - Wire decoding

/// The fallback when neither the item, its command nor its extension names an icon.
private let extensionIcon = Item.Icon.symbol(name: "puzzlepiece.extension")

extension Item: Decodable {
    /// Decodes an extension's item. A missing id is the title, a missing icon the one in the
    /// decoder's `WireContext`, a missing relevance `match` (answers set their own).
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object([
            "id", "title", "subtitle", "icon", "accessory", "relevance", "actions",
        ])
        title = try object.nonEmpty("title")
        id = try object.optionalNonEmpty("id") ?? title
        subtitle = try object.optional("subtitle")
        icon = try object.optional("icon") ?? decoder.wire.icon ?? extensionIcon
        accessory = try object.optional("accessory")
        relevance = .match
        if object.has("relevance") {
            if let mode = decoder.wire.mode, mode != .root {
                throw object.invalid("relevance", "is only for root commands; this is a \(mode) command")
            }
            let value = try object.required("relevance", as: String.self)
            guard let relevance = Relevance(rawValue: value), relevance != .exact else {
                throw object.invalid("relevance", "\"\(value)\" must be answer, match or fallback")
            }
            self.relevance = relevance
        }
        score = 0
        actions = try object.optional("actions") ?? []
    }
}

extension Item.Icon: Decodable {
    public init(from decoder: any Decoder) throws {
        let (kind, object) = try decoder.oneOf(["symbol", "file"], what: "an icon")
        if kind == "symbol" {
            self = .symbol(name: try object.object("symbol", ["name"]).nonEmpty("name"))
        } else {
            self = .file(url: try object.object("file", ["url"]).location("url"))
        }
    }
}

extension Item.Action: Decodable {
    public init(from decoder: any Decoder) throws {
        let (kind, object) = try decoder.oneOf(["open", "copy", "paste", "detail", "run"], what: "an action")
        switch kind {
        case "open":
            let open = try object.object(kind, ["url", "title"])
            self = .open(url: try open.location("url"), title: try open.optional("title"))
        case "copy", "paste":
            let fields = try object.object(kind, ["text", "title"])
            let text: String = try fields.required("text")
            let title: String? = try fields.optional("title")
            self = kind == "copy" ? .copy(text: text, title: title) : .paste(text: text, title: title)
        case "detail":
            self = .detail(try object.required(kind))
        default:
            let run = try object.object(kind, ["command", "args", "title"])
            let command = try run.slug("command")
            if let commands = decoder.wire.commands, !commands.contains(command) {
                throw run.invalid("command", "\"\(command)\" is not a command in wicket.json")
            }
            self = .run(command: command, args: try run.optional("args"), title: try run.optional("title"))
        }
    }
}
