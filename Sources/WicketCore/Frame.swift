import Foundation

/// One screen of the palette: the root search at the bottom of the stack, or something pushed on
/// top of it (a detail; a command's own list later). `PaletteSession` owns the stack.
public struct Frame: Identifiable, Sendable {
    public enum Content: Sendable {
        /// The root search. Only the bottom frame has it.
        case search(RootResults)
        case detail(Detail)
    }

    /// Unique within a session, so work started for a popped frame never lands on a new one.
    public let id: Int
    /// What the search field holds while the frame is on top.
    public internal(set) var query = ""
    /// Bumped whenever the query changes: work started for an older generation is dropped.
    public internal(set) var generation = 0
    public internal(set) var content: Content
    /// Slow work for the current generation still running, such as a file search.
    var pending = 0

    init(id: Int, content: Content) {
        self.id = id
        self.content = content
    }

    public var isLoading: Bool { pending > 0 }

    /// The frame's list, whose selection the arrow keys move; nil for a detail.
    public var list: ItemList? {
        switch content {
        case .search(let results): results.list
        case .detail: nil
        }
    }

    /// What Return, ⌘↩ and ⌘K act on in this frame.
    public var target: ActionTarget? {
        switch content {
        case .search(let results): results.selectedItem.map(ActionTarget.init(item:))
        case .detail(let detail): ActionTarget(detail: detail)
        }
    }

    /// Whether the palette shows just the pill: only the root search with nothing typed. An empty
    /// query in a pushed frame is still a screen with content.
    public var isCompact: Bool {
        if case .search = content { query.isEmpty } else { false }
    }

    mutating func moveSelection(by delta: Int) {
        guard case .search(var results) = content else { return }
        results.moveSelection(by: delta)
        content = .search(results)
    }
}

/// What Return, ⌘↩ and ⌘K act on: the selected item's actions, or a detail's own.
public struct ActionTarget: Sendable, Hashable {
    /// The first is the primary one, run by Return.
    public var actions: [Item.Action]
    /// The item the actions belong to, whose use is recorded; nil for a detail's actions.
    public var item: Item?

    public init(item: Item) {
        actions = item.actions
        self.item = item
    }

    /// A detail's actions; without any, Return copies the markdown (docs/extensions.md).
    public init(detail: Detail) {
        actions = detail.actions.isEmpty ? [.copy(text: detail.markdown)] : detail.actions
        item = nil
    }
}
