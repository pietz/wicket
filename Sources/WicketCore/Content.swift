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
