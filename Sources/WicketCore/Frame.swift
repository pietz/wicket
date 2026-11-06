import Foundation

/// One screen of the palette: the root search at the bottom of the stack, or something pushed on
/// top of it (a detail, or a command's frame). `PaletteSession` owns the stack.
public struct Frame: Identifiable, Sendable {
    public enum Content: Sendable {
        /// The root search. Only the bottom frame has it.
        case search(RootResults)
        /// A page pushed by a `detail` action, or a failure.
        case detail(Detail)
        /// A command, fed by its run: each result replaces what the frame shows.
        case command(CommandFrame)
    }

    /// Unique within a session, so work started for a popped frame never lands on a new one.
    public let id: Int
    /// What the search field holds while the frame is on top.
    public internal(set) var query = ""
    /// Bumped whenever the frame's work starts again (a new root or live query, a reload): work
    /// started for an older generation is dropped. A once command's local filter doesn't bump it.
    public internal(set) var generation = 0
    public internal(set) var content: Content
    /// Slow work for the current generation still running, such as a file search or a command run.
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
        case .command(let command): command.list
        }
    }

    /// What Return, ⌘↩ and ⌘K act on in this frame.
    public var target: ActionTarget? {
        switch content {
        case .search(let results): results.selectedItem.map(ActionTarget.init(item:))
        case .detail(let detail): ActionTarget(detail: detail)
        case .command(let command): command.target
        }
    }

    /// Whether the palette shows just the pill: the root search with nothing typed, or a live
    /// command with nothing typed and nothing to show (its placeholder says what to type). An empty
    /// query anywhere else is still a screen with content.
    public var isCompact: Bool {
        switch content {
        case .search: query.isEmpty
        case .detail: false
        case .command(let command):
            command.run.command.mode == .live && query.isEmpty && command.list?.items.isEmpty == true
        }
    }

    mutating func moveSelection(by delta: Int) {
        switch content {
        case .search(var results):
            results.moveSelection(by: delta)
            content = .search(results)
        case .command(var command):
            command.moveSelection(by: delta)
            content = .command(command)
        case .detail:
            break
        }
    }
}

/// A command's frame: what it runs, and what its run sent last.
///
/// A list from a `once` command is filtered locally by the frame's query with the shared fuzzy
/// matcher (best match first, the command's order breaking ties; all items in its order for an empty
/// query). A `live` command's list is shown as sent: the command did the searching. Either way the
/// selection follows its item when the content is replaced, and goes back to the top when the text
/// the list answers changes.
public struct CommandFrame: Sendable {
    public let run: CommandRun
    /// The latest content; nil until the first arrives.
    public private(set) var screen: Screen?
    /// A list's rows (filtered, for a once command) or an answer's one row, with the selection.
    public private(set) var list: ItemList?
    /// A once command's list as sent and its search index, for filtering.
    private var items: [Item] = []
    private var index = SearchIndex([])
    /// The text `list` answers (live) or is filtered by (once).
    private var listText = ""

    init(run: CommandRun) {
        self.run = run
    }

    var isLive: Bool { run.command.mode == .live }

    var target: ActionTarget? {
        switch screen {
        case .detail(let detail): ActionTarget(detail: detail)
        case .answer, .list: list?.selectedItem.map(ActionTarget.init(item:))
        case nil: nil
        }
    }

    /// Replaces the content with `screen`, which answers `text` (the frame's query when it arrived).
    mutating func show(_ screen: Screen, text: String) {
        self.screen = screen
        switch screen {
        case .list(let sent):
            var list = self.list ?? ItemList()
            let reset = text != listText || self.list == nil
            if isLive {
                list.replace(with: sent, resettingSelection: reset)
            } else {
                items = sent
                index = SearchIndex(sent.map { ($0, []) })
                list.replace(with: filtered(text), resettingSelection: reset)
            }
            self.list = list
            listText = text
        case .answer(let item):
            var list = self.list ?? ItemList()
            list.replace(with: [item])
            self.list = list
        case .detail:
            list = nil
        }
    }

    /// Filters a once command's list by `text`; does nothing for anything else.
    mutating func filter(_ text: String) {
        guard !isLive, case .list = screen, var list else { return }
        list.replace(with: filtered(text), resettingSelection: text != listText)
        self.list = list
        listText = text
    }

    mutating func moveSelection(by delta: Int) {
        list?.moveSelection(by: delta)
    }

    /// The items matching `text`, best first, as sent: the match only orders them.
    private func filtered(_ text: String) -> [Item] {
        guard !Fold.query(text).isEmpty else { return items }
        // `search` keeps the input order (item ids are unique), so ties stay in the command's order.
        let matches = index.search(text).enumerated().sorted { a, b in
            if a.element.relevance != b.element.relevance { return a.element.relevance < b.element.relevance }
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }
        let sent = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return matches.compactMap { sent[$0.element.id] }
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
