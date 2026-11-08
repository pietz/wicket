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

    /// A command's frame whose run has sent nothing yet: the pill spins, the card keeps its height,
    /// and other actions wait, so commands start one at a time.
    public var isStarting: Bool {
        if case .screen(let screen) = content { isLoading && screen.screen == nil } else { false }
    }

    /// The frame's list, whose selection the arrow keys move; nil for a screen without rows.
    public var list: ItemList? {
        switch content {
        case .search(let results): results.list
        case .screen(let screen): screen.list
        }
    }

    /// What Return, ⌘↩ and ⌘K act on in this frame. A page still loading without actions of its own
    /// has none: the copy a finished one gets would take a status, such as "Asking…", or half a page.
    public var target: ActionTarget? {
        switch content {
        case .search(let results): return results.selectedItem.map { target(for: $0) }
        case .screen(let screen):
            if isLoading, case .detail(let detail) = screen.screen, detail.actions.isEmpty,
                screen.context.actions.isEmpty
            {
                return nil
            }
            return screen.target(query: query)
        }
    }

    /// What clicking `item` (or ⌘1 to ⌘9 on it) acts on: its actions under the frame's authority,
    /// with the screen's own actions beside them.
    public func target(for item: Item) -> ActionTarget {
        switch content {
        case .search: ActionTarget(item: item, in: .host)
        case .screen(let screen): ActionTarget(item: item, in: screen.context)
        }
    }

    /// The command run feeding the frame; nil for the root and a pushed page.
    public var run: CommandRun? {
        if case .screen(let screen) = content { screen.run } else { nil }
    }

    /// Whether the frame is a command's waiting for its text, which a submit runs.
    public var awaitsText: Bool { run?.awaitsText == true }

    /// Whether the frame shows a document (a page), whose view lays out its content and measures it
    /// to size the card. A page made only of rows shows as a list instead.
    public var isMeasured: Bool {
        if case .screen(let screen) = content { screen.document != nil } else { false }
    }

    /// The document the frame shows, if it shows a page.
    public var document: Document? {
        if case .screen(let screen) = content { screen.document } else { nil }
    }

    /// The list the frame shows with what is said about it, if it shows one: a command's list, or a
    /// page made only of rows (not the root's results).
    public var listing: Listing? {
        if case .screen(let screen) = content { screen.listing } else { nil }
    }

    /// The summary above the frame's list, parsed.
    public var summary: Document? {
        if case .screen(let screen) = content { screen.summary } else { nil }
    }

    /// The screen action typing on this frame starts with the typed text, for a document: the first
    /// of the screen's actions that opens a frame waiting for text (Follow Up on an agent's answer),
    /// as `waitsForText` says of its command. A document is read, not searched, so typing on it
    /// continues the conversation instead of filtering; a list keeps filtering, and a page without
    /// such an action takes no text.
    public func typingAction(waitsForText: (CommandID) -> Bool) -> Item.Action? {
        guard case .screen(let screen) = content, screen.document != nil else { return nil }
        return screen.context.actions.first { action in
            guard case .run(let command, let text, _, _, _) = action else { return false }
            return text.isEmpty && waitsForText(command)
        }
    }

    /// Whether the palette shows just the pill: the root search with nothing typed, a live command
    /// with nothing typed and nothing to show, or a command waiting for its text (the placeholder says
    /// what to type). An empty query anywhere else is still a screen with content.
    public var isCompact: Bool {
        switch content {
        case .search: query.isEmpty
        case .screen(let screen):
            awaitsText || (screen.isLive && query.isEmpty && screen.list?.items.isEmpty == true)
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
/// A page's markup is parsed into a `Document` whenever it is shown (one parser per frame, so a
/// growing answer re-parses only what changed). Its targets are the frame's rows in reading order,
/// none selected until the arrows move; a page made only of rows, without actions or metadata of
/// its own, is shown as the list it is. A list's summary is parsed the same way.
///
/// A list from a `once` command (or a page shown as a list) is filtered locally by the frame's
/// query with the shared fuzzy matcher (best match first, the command's order breaking ties; all
/// items in its order for an empty query). A `live` command's list is shown as sent: the command
/// did the searching. Either way the selection follows its item when the content is replaced, and
/// goes back to the top when the text the list answers changes.
public struct ScreenFrame: Sendable {
    /// The command feeding the frame; nil for a pushed page.
    public private(set) var run: CommandRun?
    /// The latest content; nil until a command's first arrives.
    public private(set) var screen: Screen?
    /// Who made `screen` and the host's actions for it; a pushed page has the authority of the
    /// screen that pushed it.
    public private(set) var context = ScreenContext.host
    /// The screen's rows (a list's filtered, for a once command; a document's targets) with the
    /// selection.
    public private(set) var list: ItemList?
    /// The page as a document; nil for anything shown as a list.
    public private(set) var document: Document?
    /// The list on screen with its sections: a command's, or a page made only of rows.
    public private(set) var listing: Listing?
    /// The list's summary as a document.
    public private(set) var summary: Document?
    /// A list as sent and its search index, for filtering.
    private var items: [Item] = []
    private var index = SearchIndex([])
    /// The text `list` answers (live) or is filtered by (once).
    private var listText = ""
    /// Parses the page, keeping what it parsed for the next, longer text of a growing answer.
    private var parser = Markup.Parser()
    /// The page as plain text, which Return copies on a page without actions of its own.
    private var pageText = ""
    /// How many problems the last parse found, so a growing answer logs them once, not per redraw.
    private var issueCount = 0

    /// A command's frame, empty until its run sends something.
    init(run: CommandRun) {
        self.run = run
    }

    /// A pushed page, with no run behind it.
    init(showing screen: Screen, _ context: ScreenContext) {
        run = nil
        show(screen, context, text: "")
    }

    var isLive: Bool { run?.command.input == .liveText }

    /// What Return acts on; a frame waiting for its text submits `query`, once there is one, as its
    /// own invocation with only the text replaced (the args and revision it was opened with stay).
    /// On a document, the selected target's actions, or with none selected the page's own; with no
    /// row at all, the screen's alone.
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
        if let item = list?.selectedItem { return ActionTarget(item: item, in: context) }
        if document != nil, case .detail(let detail) = screen {
            return ActionTarget(detail: detail, text: pageText, in: context)
        }
        // No row (a filter that matches none): the screen's actions stay, Copy Answer and Follow Up.
        return context.actions.isEmpty ? nil : ActionTarget(actions: [], in: context)
    }

    /// Replaces the content with `screen`, which answers `text` (the frame's query when it arrived).
    /// A list is filtered and keeps its selection by the text; a document's targets replace the
    /// list's, following the selected one.
    mutating func show(_ screen: Screen, _ context: ScreenContext, text: String) {
        self.screen = screen
        self.context = context
        document = nil
        listing = nil
        summary = nil
        switch screen {
        case .answer(let item):
            replaceRows(with: [item])
        case .list(let list):
            listing = list
            summary = list.summary.map { parse($0, .summary).document }
            showList(list.items, text: text)
        case .detail(let detail):
            let parsed = parse(detail.markdown, .page)
            if detail.actions.isEmpty, detail.metadata.isEmpty, let rows = parsed.document.listing {
                listing = rows
                showList(rows.items, text: text)
                return
            }
            document = parsed.document
            pageText =
                detail.actions.isEmpty && context.authority != .agent
                ? Markup.plainText(detail.markdown, document: parsed.document, home: home) : ""
            var targets = list?.selectsFirst == false ? list! : ItemList(selectsFirst: false)
            targets.replace(with: parsed.document.targets)
            list = targets
        }
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Parses markup shown in this frame, its rows stamped with the frame's extension command.
    private mutating func parse(_ text: String, _ placement: Markup.Context.Placement) -> Markup.Parsed {
        let origin = run.flatMap { if case .extension = $0.command.id.owner { $0.command.id } else { nil } }
        parser.context = Markup.Context(placement: placement, origin: origin, home: home)
        let parsed = parser.parse(text)
        if parsed.issues.count != issueCount { Markup.log(parsed.issues) }
        issueCount = parsed.issues.count
        return parsed
    }

    /// Rows that aren't filtered (an answer's), replacing the list's and following its selection.
    private mutating func replaceRows(with rows: [Item]) {
        var list = self.list?.selectsFirst == true ? self.list! : ItemList()
        list.replace(with: rows)
        self.list = list
    }

    /// A list's rows, searched by the command (live) or filtered here by `text` (once).
    private mutating func showList(_ rows: [Item], text: String) {
        let previous = self.list?.selectsFirst == true ? self.list : nil
        var list = previous ?? ItemList()
        let reset = text != listText || previous == nil
        if isLive {
            list.replace(with: rows, resettingSelection: reset)
        } else {
            items = rows
            index = SearchIndex(rows.map { ($0, []) })
            list.replace(with: filtered(text), resettingSelection: reset)
        }
        listText = text
        self.list = list
    }

    /// Filters a once command's list by `text`; does nothing for anything else.
    mutating func filter(_ text: String) {
        guard !isLive, listing != nil, var list else { return }
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

/// What Return, ⌘↩ and ⌘K act on: the selected item's actions, or a page's own, under the
/// authority of the screen they're on, and the screen's own actions (the host's, for the whole
/// screen: Follow Up, Copy Answer), which run as the host.
public struct ActionTarget: Sendable, Hashable {
    /// The selected item's or the page's own actions.
    public var actions: [Item.Action]
    /// The item the actions belong to, whose use is recorded; nil for a page's actions.
    public var item: Item?
    /// Who sent `actions`, which decides what activating one does (`ActionPolicy`).
    public var authority: Authority
    /// The screen's own actions, the host's; the action panel shows them as a group of their own.
    public var screen: [Item.Action]
    /// What Return runs: the first action, or the screen's first when there is no action of its own
    /// (an agent's answer with nothing selected: Copy Answer).
    public let primary: Position
    /// What ⌘↩ runs: the screen's action it names (`ScreenContext.secondary`, Follow Up on an
    /// agent's screen) when it came with any, else the second action, as on every other screen.
    public let secondary: Position

    /// An action of the target: one of its `actions`, or one of the screen's.
    public enum Position: Sendable, Hashable {
        case action(Int)
        case screen(Int)
    }

    /// A row's actions; Return runs its first, and a row without any runs nothing.
    public init(item: Item, in context: ScreenContext) {
        self.init(actions: item.actions, in: context, primary: .action(0))
        self.item = item
    }

    /// Actions that belong to no item, such as submitting a frame's text or a page's own; with none,
    /// Return runs the screen's first.
    public init(actions: [Item.Action], in context: ScreenContext = .host) {
        self.init(
            actions: actions, in: context,
            primary: actions.isEmpty && !context.actions.isEmpty ? .screen(0) : .action(0))
    }

    private init(actions: [Item.Action], in context: ScreenContext, primary: Position) {
        self.actions = actions
        item = nil
        authority = context.authority
        screen = context.actions
        self.primary = primary
        secondary =
            context.actions.isEmpty
            ? .action(1)
            : .screen(context.actions.indices.contains(context.secondary) ? context.secondary : 0)
    }

    /// A page's actions; without any, Return copies `text`, the page as plain text
    /// (docs/extensions.md). An agent's page has none: its screen's Copy Answer does that.
    public init(detail: Detail, text: String, in context: ScreenContext) {
        let copy = context.authority == .agent ? [] : [Item.Action.copy(text: text)]
        self.init(actions: detail.actions.isEmpty ? copy : detail.actions, in: context)
    }

    /// The action at `position` and the authority it runs under; nil if there is none.
    public func action(at position: Position) -> (action: Item.Action, authority: Authority)? {
        switch position {
        case .action(let index): actions.indices.contains(index) ? (actions[index], authority) : nil
        case .screen(let index): screen.indices.contains(index) ? (screen[index], .host) : nil
        }
    }
}
