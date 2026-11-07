import Foundation

/// One screen of the palette: the root search at the bottom of the stack, or a screen pushed on top
/// of it (a command's, or a page). `PaletteSession` owns the stack.
public struct Frame: Identifiable, Sendable {
    public enum Content: Sendable {
        /// The root search. Only the bottom frame has it.
        case search(RootResults)
        /// A command's screen, fed by its run, or a page pushed by a `detail` action.
        case screen(ScreenFrame)
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

    /// The frame's list, whose selection the arrow keys move; nil for a screen without rows.
    public var list: ItemList? {
        switch content {
        case .search(let results): results.list
        case .screen(let screen): screen.list
        }
    }

    /// What Return, ⌘↩ and ⌘K act on in this frame.
    public var target: ActionTarget? {
        switch content {
        case .search(let results): results.selectedItem.map(ActionTarget.init(item:))
        case .screen(let screen): screen.target(query: query)
        }
    }

    /// Whether the frame shows a screen without rows (a page), whose view lays out its content and
    /// measures it to size the card.
    public var isMeasured: Bool {
        guard case .screen(let screen) = content, let shown = screen.screen else { return false }
        return shown.items == nil
    }

    /// Whether the palette shows just the pill: the root search with nothing typed, a live command
    /// with nothing typed and nothing to show, or a command waiting for its text (the placeholder says
    /// what to type). An empty query anywhere else is still a screen with content.
    public var isCompact: Bool {
        switch content {
        case .search: query.isEmpty
        case .screen(let screen):
            screen.run?.awaitsText == true
                || (screen.isLive && query.isEmpty && screen.list?.items.isEmpty == true)
        }
    }

    mutating func moveSelection(by delta: Int) {
        switch content {
        case .search(var results):
            results.moveSelection(by: delta)
            content = .search(results)
        case .screen(var screen):
            screen.moveSelection(by: delta)
            content = .screen(screen)
        }
    }
}

/// A frame's screen: what it shows, and the command run feeding it, if any.
///
/// A command's frame starts without content and each result of its run replaces it. A page pushed
/// by a `detail` action (or a failure saying what went wrong) has no run: it shows its screen and
/// never runs, so a reload of it does nothing.
///
/// A list from a `once` command is filtered locally by the frame's query with the shared fuzzy
/// matcher (best match first, the command's order breaking ties; all items in its order for an empty
/// query). A `live` command's list is shown as sent: the command did the searching. Either way the
/// selection follows its item when the content is replaced, and goes back to the top when the text
/// the list answers changes.
public struct ScreenFrame: Sendable {
    /// The command feeding the frame; nil for a pushed page.
    public private(set) var run: CommandRun?
    /// The latest content; nil until a command's first arrives.
    public private(set) var screen: Screen?
    /// The screen's rows (a list's filtered, for a once command) with the selection.
    public private(set) var list: ItemList?
    /// A once command's list as sent and its search index, for filtering.
    private var items: [Item] = []
    private var index = SearchIndex([])
    /// The text `list` answers (live) or is filtered by (once).
    private var listText = ""

    /// A command's frame, empty until its run sends something.
    init(run: CommandRun) {
        self.run = run
    }

    /// A pushed page, with no run behind it.
    init(showing screen: Screen) {
        run = nil
        show(screen, text: "")
    }

    var isLive: Bool { run?.command.input == .liveText }

    /// Feeds the frame from `run` from now on, keeping what it shows until that sends something.
    mutating func rebind(_ run: CommandRun) {
        self.run = run
    }

    /// What Return acts on; a frame waiting for its text submits `query`, once there is one, as its
    /// own invocation with only the text replaced (the args and revision it was opened with stay).
    func target(query: String) -> ActionTarget? {
        if let run, run.awaitsText {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let invocation = run.invocation
            return ActionTarget(actions: [
                .run(
                    command: invocation.command, text: query, args: invocation.args, title: run.command.title,
                    revision: invocation.revision)
            ])
        }
        return screen?.target ?? list?.selectedItem.map(ActionTarget.init(item:))
    }

    /// Replaces the content with `screen`, which answers `text` (the frame's query when it arrived).
    /// Only a list is filtered and keeps its selection by the text; any other rows replace the
    /// list's, following the selected item.
    mutating func show(_ screen: Screen, text: String) {
        self.screen = screen
        guard let rows = screen.items else {
            list = nil
            return
        }
        var list = self.list ?? ItemList()
        if case .list = screen {
            let reset = text != listText || self.list == nil
            if isLive {
                list.replace(with: rows, resettingSelection: reset)
            } else {
                items = rows
                index = SearchIndex(rows.map { ($0, []) })
                list.replace(with: filtered(text), resettingSelection: reset)
            }
            listText = text
        } else {
            list.replace(with: rows)
        }
        self.list = list
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

    /// Actions that belong to no item, such as submitting a frame's text.
    public init(actions: [Item.Action]) {
        self.actions = actions
        item = nil
    }

    /// A detail's actions; without any, Return copies the markdown (docs/extensions.md).
    public init(detail: Detail) {
        actions = detail.actions.isEmpty ? [.copy(text: detail.markdown)] : detail.actions
        item = nil
    }
}
