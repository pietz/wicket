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

/// What a command shows or does: the `result` of an extension's response.
public enum RunResult: Sendable, Hashable {
    /// One item, shown large; ranks as an answer in root mode unless it says otherwise.
    case answer(Item)
    /// Items in the producer's order.
    case list([Item])
    case detail(Detail)
    case close(message: String?)
    /// Re-runs the view the user is looking at.
    case reload(message: String?)
}

/// What a pushed frame shows: `RunResult`'s content cases.
public enum Screen: Sendable, Hashable {
    /// One item, shown large.
    case answer(Item)
    /// Items in the producer's order.
    case list([Item])
    case detail(Detail)
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
