import Foundation

// What a screen shows or a command does: the content vocabulary for every producer, built-in or
// extension. The wire format (Extension/Decoding.swift) is one encoding of it.

/// A markdown page with optional metadata and actions: a detail result, or a `detail` action.
public struct Detail: Sendable, Hashable {
    public struct Metadata: Sendable, Hashable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var title: String?
    public var markdown: String
    public var metadata: [Metadata]
    public var actions: [Item.Action]

    public init(
        title: String? = nil, markdown: String, metadata: [Metadata] = [], actions: [Item.Action] = []
    ) {
        self.title = title
        self.markdown = markdown
        self.metadata = metadata
        self.actions = actions
    }
}

/// What a command's run sends: something to show, or what to do with the palette.
public enum RunResult: Sendable, Hashable {
    /// Replaces what the command's frame shows: a screen, who made it and the host's actions for it.
    case show(Screen, ScreenContext = .host)
    case close(message: String?)
    /// Re-runs the view the user is looking at.
    case reload(message: String?)
    /// Leaves the palette as it was: the command's own frame goes, and the frame beneath keeps
    /// running. For an action that answers the screen it was chosen on, such as an agent's approval.
    case stay

    /// The results a producer can send, by their wire names; `ActionPolicy` says who may send which.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case answer, list, detail, close, reload
    }
}

/// What a frame knows about its screen besides the content: who made it, which decides what its
/// rows' and page's actions may do, and the host's actions for the whole screen (Follow Up, Copy
/// Answer, Retry), which belong to no row and always run as the host. The wire never carries it.
public struct ScreenContext: Sendable, Hashable {
    public var authority: Authority
    public var actions: [Item.Action]
    /// Which of `actions` ⌘↩ runs (Follow Up on an answer), whatever is selected: the first unless
    /// the screen says otherwise.
    public var secondary: Int

    public init(authority: Authority, actions: [Item.Action] = [], secondary: Int = 0) {
        self.authority = authority
        self.actions = actions
        self.secondary = secondary
    }

    public static let host = ScreenContext(authority: .host)
}

/// A list screen: an optional summary above one collection of rows, flat or in titled sections.
/// Flat rows are one section without a title.
public struct Listing: Sendable, Hashable, ExpressibleByArrayLiteral {
    public struct Section: Sendable, Hashable {
        /// Nil for a flat list's one section.
        public var title: String?
        public var items: [Item]

        public init(title: String?, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    /// Markup above the rows (placement `summary`: nothing in it is selectable).
    public var summary: String?
    public var sections: [Section]

    public init(_ items: [Item], summary: String? = nil) {
        self.init(sections: [Section(title: nil, items: items)], summary: summary)
    }

    public init(sections: [Section], summary: String? = nil) {
        self.summary = summary
        self.sections = sections
    }

    public init(arrayLiteral items: Item...) {
        self.init(items)
    }

    /// Every row, in order, sections one after another.
    public var items: [Item] { sections.flatMap(\.items) }

    /// The section title to draw above each of `rows` (the rows on screen, which a search may have
    /// filtered), nil where none goes: above the first shown row of each titled section. Only while
    /// the rows keep the sections' order: a search that ranks them across sections draws no titles,
    /// since a title would then head rows that aren't its own.
    public func headerTitles(for rows: [Item]) -> [String?] {
        let none = [String?](repeating: nil, count: rows.count)
        guard sections.contains(where: { $0.title != nil }) else { return none }
        var sectionOf: [String: Int] = [:]
        for (index, section) in sections.enumerated() {
            for item in section.items where sectionOf[item.id] == nil { sectionOf[item.id] = index }
        }
        var titles = none
        var previous = -1
        for (row, item) in rows.enumerated() {
            guard let section = sectionOf[item.id], section >= previous else { return none }
            if section != previous { titles[row] = sections[section].title }
            previous = section
        }
        return titles
    }
}

/// What a frame above the root shows: a command's latest content, or a page pushed by a `detail`
/// action. A new kind of screen (a grid, a form) is a case here, its decoding, and its view.
public enum Screen: Sendable, Hashable {
    /// One item, shown large.
    case answer(Item)
    /// Items in the producer's order, with what is said about them.
    case list(Listing)
    case detail(Detail)

    /// The rows the screen shows, which the selection moves through: an answer's one, a list's
    /// items. Nil for a screen whose view lays out its own content (a page): it takes no text, and
    /// its card is sized by measuring that view.
    public var items: [Item]? {
        switch self {
        case .answer(let item): [item]
        case .list(let list): list.items
        case .detail: nil
        }
    }

    /// The screen's own title, which the pill shows: a page's.
    public var title: String? {
        switch self {
        case .answer, .list: nil
        case .detail(let detail): detail.title
        }
    }
}

extension Detail {
    /// A failure the user sees, as a page they can copy (Return) and leave (Escape): what failed,
    /// the message, and the command.
    public static func failure(_ title: String, _ message: String, command: CommandID) -> Detail {
        let name =
            switch command.owner {
            case .builtin: command.name
            case .extension(let id): "\(id)/\(command.name)"
            }
        return Detail(title: title, markdown: message, metadata: [.init(label: "Command", value: name)])
    }
}
