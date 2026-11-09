import Foundation

/// One screen of the palette: the root search at the bottom of the stack, or a screen pushed on top
/// of it, a command's (fed by its run) or a page pushed by a `detail` action. `PaletteSession` owns
/// the stack. A page's markup is parsed once per change into a `Document` whose targets are the
/// rows, none selected at first; a once command's list is filtered here by the frame's query, a live
/// command's is shown as sent (docs/architecture.md, "Documents").
public struct Frame: Identifiable, Sendable {
    /// Unique within a session, so work started for a popped frame never lands on a new one.
    public let id: Int
    /// What the search field holds while the frame is on top.
    public internal(set) var query = ""
    /// Bumped whenever the frame's work starts again (a new root or live query, a reload): work
    /// started for an older generation is dropped. A once command's local filter doesn't bump it.
    public internal(set) var generation = 0
    /// Slow work for the current generation still running, such as a file search or a command run.
    var pending = 0
    /// The root search's results; nil for every frame above it.
    public internal(set) var results: RootResults?
    /// The command feeding the frame; nil for the root and a pushed page.
    public private(set) var run: CommandRun?
    /// The latest content; nil for the root, and until a command's first arrives.
    public private(set) var screen: Screen?
    /// Who made `screen` and the host's actions for it; a pushed page has the authority of the
    /// screen that pushed it.
    public private(set) var context = ScreenContext.host
    /// The page as a document; nil for anything shown as a list.
    public private(set) var document: Document?
    /// A command's list, or a page made only of rows (not the root's results).
    public private(set) var listing: Listing?
    /// The summary above the frame's list, parsed.
    public private(set) var summary: Document?
    /// The screen's rows (a list's filtered, for a once command; a document's targets) with the
    /// selection.
    private var rows: ItemList?
    /// A list as sent and its search index, for filtering.
    private var items: [Item] = []
    private var index = SearchIndex([])
    /// The text `rows` answers (live) or is filtered by (once).
    private var listText = ""
    /// Parses the page, keeping what it parsed for the next, longer text of a growing answer.
    private var parser = Markup.Parser()
    /// The page as plain text, which Return copies on a page without actions of its own.
    private var pageText = ""
    /// How many problems the last parse found, so a growing answer logs them once, not per redraw.
    private var issueCount = 0

    /// The root search.
    init(id: Int, results: RootResults) {
        self.id = id
        self.results = results
    }

    /// A command's frame, empty until its run sends something; its field starts with the run's query.
    init(id: Int, run: CommandRun) {
        self.id = id
        self.run = run
        query = run.query
    }

    /// A pushed page, with no run behind it.
    init(id: Int, showing screen: Screen, _ context: ScreenContext) {
        self.id = id
        show(screen, context, text: "")
    }

    public var isLoading: Bool { pending > 0 }

    /// A command's frame whose run has sent nothing yet: the pill spins, the card keeps its height,
    /// and other actions wait, so commands start one at a time.
    public var isStarting: Bool { run != nil && isLoading && screen == nil }

    /// The frame's list, whose selection the arrow keys move; nil for a screen without rows.
    public var list: ItemList? { results?.list ?? rows }

    var isLive: Bool { run?.command.input == .liveText }

    /// Whether the frame is a command's waiting for its text, which a submit runs.
    public var awaitsText: Bool { run?.awaitsText == true }

    /// Whether the frame shows a page, whose view measures it to size the card.
    public var isMeasured: Bool { document != nil }

    /// What Return, ⌘↩ and ⌘K act on in this frame; a frame waiting for its text submits `query`,
    /// once there is one, as its own invocation with only the text replaced (the args and revision
    /// it was opened with stay). On a document, the selected target's actions, or with none
    /// selected the page's own; with no row at all, the screen's alone. A page still loading without
    /// actions of its own has none: the copy a finished one gets would take a status, such as
    /// "Asking…", or half a page.
    public var target: ActionTarget? {
        if let results { return results.selectedItem.map { target(for: $0) } }
        if isLoading, case .detail(let detail)? = screen, detail.actions.isEmpty, context.actions.isEmpty {
            return nil
        }
        if let run, run.awaitsText {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let invocation = run.invocation
            return ActionTarget(actions: [
                .run(
                    command: invocation.command, text: query, args: invocation.args, title: run.command.title,
                    revision: invocation.revision)
            ])
        }
        if let item = rows?.selectedItem { return ActionTarget(item: item, in: context) }
        if document != nil, case .detail(let detail) = screen {
            return ActionTarget(detail: detail, text: pageText, in: context)
        }
        // No row (a filter that matches none): the screen's actions stay, Copy Answer and Follow Up.
        return context.actions.isEmpty ? nil : ActionTarget(actions: [], in: context)
    }

    /// What clicking `item` (or ⌘1 to ⌘9 on it) acts on: its actions under the frame's authority,
    /// with the screen's own actions beside them.
    public func target(for item: Item) -> ActionTarget {
        ActionTarget(item: item, in: results == nil ? context : .host)
    }

    /// What typing on a page starts with the typed text: the first screen action whose command waits
    /// for text (Follow Up on an answer, New Command on shell output). The action takes precedence
    /// over filtering when an answer happens to contain only rows.
    public func typingAction(waitsForText: (CommandID) -> Bool) -> Item.Action? {
        guard screen != nil else { return nil }
        return context.actions.first { action in
            guard case .run(let command, let text, _, _, _) = action else { return false }
            return text.isEmpty && waitsForText(command)
        }
    }

    /// Whether the palette shows just the pill: the root search with nothing typed, a live command
    /// with nothing typed and nothing to show, or a command waiting for its text (the placeholder says
    /// what to type). An empty query anywhere else is still a screen with content.
    public var isCompact: Bool {
        if results != nil { return query.isEmpty }
        return awaitsText || (isLive && query.isEmpty && rows?.items.isEmpty == true)
    }

    mutating func moveSelection(by delta: Int) {
        if results != nil { results?.moveSelection(by: delta) } else { rows?.moveSelection(by: delta) }
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
            var targets = rows?.selectsFirst == false ? rows! : ItemList(selectsFirst: false)
            targets.replace(with: parsed.document.targets)
            rows = targets
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
    private mutating func replaceRows(with items: [Item]) {
        var list = rows?.selectsFirst == true ? rows! : ItemList()
        list.replace(with: items)
        rows = list
    }

    /// A list's rows, searched by the command (live) or filtered here by `text` (once).
    private mutating func showList(_ items: [Item], text: String) {
        let previous = rows?.selectsFirst == true ? rows : nil
        var list = previous ?? ItemList()
        let reset = text != listText || previous == nil
        if isLive {
            list.replace(with: items, resettingSelection: reset)
        } else {
            self.items = items
            index = SearchIndex(items.map { ($0, []) })
            list.replace(with: filtered(text), resettingSelection: reset)
        }
        listText = text
        rows = list
    }

    /// Filters a once command's list by `text`; does nothing for anything else.
    mutating func filter(_ text: String) {
        guard !isLive, listing != nil, var list = rows else { return }
        list.replace(with: filtered(text), resettingSelection: text != listText)
        rows = list
        listText = text
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
