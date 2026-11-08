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
    /// Replaces what the command's frame shows.
    case show(Screen)
    case close(message: String?)
    /// Re-runs the view the user is looking at.
    case reload(message: String?)
    /// Leaves the palette as it was: the command's own frame goes, and the frame beneath keeps
    /// running. For an action that answers the screen it was chosen on, such as an agent's approval.
    case stay
}

/// What a frame above the root shows: a command's latest content, or a page pushed by a `detail`
/// action. A new kind of screen (a grid, a form) is a case here, its decoding, and its view.
public enum Screen: Sendable, Hashable {
    /// One item, shown large.
    case answer(Item)
    /// Items in the producer's order.
    case list([Item])
    case detail(Detail)

    /// The rows the screen shows, which the selection moves through: an answer's one, a list's
    /// items. Nil for a screen whose view lays out its own content (a page): it takes no text, and
    /// its card is sized by measuring that view.
    public var items: [Item]? {
        switch self {
        case .answer(let item): [item]
        case .list(let items): items
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

    /// What Return, ⌘↩ and ⌘K act on that belongs to the screen rather than a row: a page's actions.
    public var target: ActionTarget? {
        switch self {
        case .answer, .list: nil
        case .detail(let detail): ActionTarget(detail: detail)
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
