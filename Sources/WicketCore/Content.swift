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

    public init(authority: Authority, actions: [Item.Action] = []) {
        self.authority = authority
        self.actions = actions
    }

    public static let host = ScreenContext(authority: .host)
}

/// A list screen: an optional markdown summary and labelled facts above one collection of rows,
/// flat or in titled sections. Flat rows are one section without a title.
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

    /// Markdown pinned above the rows.
    public var summary: String?
    /// Labelled values under the summary.
    public var facts: [Detail.Metadata]
    public var sections: [Section]

    public init(_ items: [Item], summary: String? = nil, facts: [Detail.Metadata] = []) {
        self.init(sections: [Section(title: nil, items: items)], summary: summary, facts: facts)
    }

    public init(sections: [Section], summary: String? = nil, facts: [Detail.Metadata] = []) {
        self.summary = summary
        self.facts = facts
        self.sections = sections
    }

    public init(arrayLiteral items: Item...) {
        self.init(items)
    }

    /// Every row, in order, sections one after another.
    public var items: [Item] { sections.flatMap(\.items) }
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

    /// The screen as plain text, which Copy Answer copies: a list's summary, its facts and one line
    /// per row (under its section's title); an answer's line; a page's markdown and metadata.
    public func text(home: URL) -> String {
        func facts(_ facts: [Detail.Metadata]) -> String? {
            facts.isEmpty ? nil : facts.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        }
        func line(_ item: Item) -> String {
            let parts = [item.title, item.subject?.location(home: home) ?? item.subtitle, item.accessory]
            return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let blocks: [String?]
        switch self {
        case .answer(let item):
            blocks = [line(item)]
        case .list(let list):
            let rows = list.sections.filter { !$0.items.isEmpty }.map { section in
                let lines = section.items.map { "- " + line($0) }
                return ([section.title].compactMap { $0 } + lines).joined(separator: "\n")
            }
            blocks = [list.summary, facts(list.facts)] + rows
        case .detail(let detail):
            blocks = [detail.markdown, facts(detail.metadata)]
        }
        return blocks.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
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
