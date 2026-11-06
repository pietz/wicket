import Foundation

/// What the user has typed, numbered so late results for an older query can be told apart.
public struct Query: Codable, Sendable, Hashable {
    public var text: String
    /// Increases with every new query; results carry it back so stale ones are dropped.
    public var generation: Int

    public init(text: String, generation: Int) {
        self.text = text
        self.generation = generation
    }
}

/// One result row, from any source. Extensions send the same shape: its `Decodable` conformance
/// (Extension/Decoding.swift) is the wire format of docs/extensions.md.
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
        /// Shows a file, folder or app selected in a Finder window. Host only: extensions can't send it.
        case reveal(url: URL, title: String? = nil)
        /// Pushes a detail view; its title names the action.
        case detail(Detail)
        /// Runs a command, built-in or extension, with `args` passed through. Extensions name a
        /// command of their own; the host resolves it against the item's origin when decoding, so
        /// only the host can name a built-in. `text` is submitted to the command (host only, such as a
        /// fallback row's query; a wire `run` sends `""`). `revision` is the extension revision whose
        /// output carried the action (stamped at decode, nil for the host's own): the run is refused
        /// if the extension has changed since, so replaced code never runs from a stale row.
        case run(
            command: CommandID, text: String = "", args: [String: JSONValue]? = nil, title: String? = nil,
            revision: ExtensionRevision? = nil)

        /// The title the source gave, if any.
        public var title: String? {
            switch self {
            case .open(_, let title), .copy(_, let title), .paste(_, let title), .reveal(_, let title),
                .run(_, _, _, let title, _):
                title
            case .detail(let detail): detail.title
            }
        }
    }

    /// Ranking tiers owned by the host, best first. Sources pick a tier; the score orders within it.
    public enum Relevance: String, Codable, Sendable, Hashable, Comparable {
        /// The query is exactly the alias the user gave the command (settings.json `commands`): the
        /// user's explicit choice, so it beats every other match, an app of that name included.
        case alias
        /// The query is exactly the title or an alternate name (a keyword, an app's other name).
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
            case .alias: 0
            case .exact: 1
            case .answer: 2
            case .match: 3
            case .fallback: 4
            }
        }
    }

    /// Namespaced by source and stable across launches ("apps:/Applications/Safari.app"); frecency
    /// and the selection follow it. Extension items arrive with their own id (or their title), which
    /// decoding namespaces by origin ("ext:github/search:pr-12"), so extensions can't collide.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var accessory: String?
    public var relevance: Relevance
    /// Orders the host's own items within a relevance tier, such as `SearchIndex`'s fuzzy-matcher
    /// score. Extension items keep the order they were sent in instead (`Ranker`). Host only.
    public var score: Double
    /// The first action is the primary one, run by Return.
    public var actions: [Action]
    /// The command that produced the item, stamped by the host when decoding an extension's
    /// response; for a fallback row, the command it runs (its place in the user's fallback order).
    /// Nil for the host's other sources (apps, files, calculator, built-in commands).
    public var origin: CommandID?

    public init(
        id: String, title: String, subtitle: String? = nil, icon: Icon, accessory: String? = nil,
        relevance: Relevance = .match, score: Double = 0, actions: [Action], origin: CommandID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory
        self.relevance = relevance
        self.score = score
        self.actions = actions
        self.origin = origin
    }
}
