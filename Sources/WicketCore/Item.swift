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

/// One result row, from any source. Codable because external extensions will send the same shape.
public struct Item: Codable, Sendable, Hashable, Identifiable {
    public enum Icon: Codable, Sendable, Hashable {
        /// The Finder icon of a file, folder or app.
        case file(url: URL)
        case symbol(name: String)
    }

    public enum Action: Codable, Sendable, Hashable {
        /// Opens a file, folder, app or web URL.
        case open(url: URL)
        case copy(text: String)
        /// Runs one of Wicket's built-in commands.
        case command(id: String)
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
    /// and the selection follow it.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    public var accessory: String?
    public var relevance: Relevance
    /// Orders items within a relevance tier; `SearchIndex` uses the fuzzy-matcher score.
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
