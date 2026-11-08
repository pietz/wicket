import Foundation

/// A reply or page as Wicket draws it: prose and native components in reading order, parsed from
/// markup (`Markup.Parser`). Components with targets hold them as `Item`s, so subjects, derived
/// actions and `ActionPolicy` apply as they do in a list.
public struct Document: Sendable, Hashable {
    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public enum Block: Sendable, Hashable {
        /// Prose between tags, as its source and its blocks.
        case markdown(Markdown)
        /// Source shown exactly as written: a tag that isn't valid, or what lies past a limit.
        case text(String)
        /// A registered component's node; the view registered for its type draws it.
        case component(any Component)

        public static func == (a: Block, b: Block) -> Bool {
            switch (a, b) {
            case (.markdown(let a), .markdown(let b)): a == b
            case (.text(let a), .text(let b)): a == b
            case (.component(let a), .component(let b)): a.isEqual(b)
            default: false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .markdown(let markdown): hasher.combine(markdown)
            case .text(let text): hasher.combine(text)
            case .component(let component):
                hasher.combine(ObjectIdentifier(type(of: component)))
                hasher.combine(component)
            }
        }

        /// The component, if it is one of type `type`.
        public func component<C: Component>(_ type: C.Type) -> C? {
            if case .component(let component) = self { component as? C } else { nil }
        }
    }

    public struct Markdown: Sendable, Hashable {
        public var source: String
        public var blocks: [MarkdownBlock]
    }

    /// A semantic color: the author's claim, never Wicket's verification.
    public enum Tone: String, Sendable, Hashable {
        case info, positive, warning, negative
    }
}

extension Document {
    /// What the arrows move through, in reading order (a column completely, then the next). Each id
    /// is stable across parses of the same text and unique in the document, so a selection can
    /// follow it.
    public var targets: [Item] { Self.targets(blocks) }

    /// The document as plain text, which Copy Answer copies: prose as written, each component as
    /// its own text, blocks separated by a blank line.
    public func text(home: URL) -> String { Self.text(blocks, home: home) }

    /// The targets of `blocks`, for a component that holds blocks.
    public static func targets(_ blocks: [Block]) -> [Item] {
        blocks.flatMap { block -> [Item] in
            if case .component(let component) = block { component.targets } else { [] }
        }
    }

    /// The text of `blocks`, for a component that holds blocks.
    public static func text(_ blocks: [Block], home: URL) -> String {
        blocks.map { block in
            switch block {
            case .markdown(let markdown): markdown.source
            case .text(let text): text
            case .component(let component): component.text(home: home)
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// `parts` without the missing and empty ones, joined by " · ": a line of Copy Answer text.
    static func line(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `value` without a fraction when it is whole.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

extension Item {
    /// The row as one line of text: title, where it is (or its subtitle) and accessory.
    func line(home: URL) -> String {
        Document.line(title, subject?.location(home: home) ?? subtitle, accessory)
    }
}
