import WicketCore

/// How an action is named and drawn in the action panel and the footer: the one place to extend
/// when `Item.Action` gains cases or titles.
struct ActionPresentation {
    let title: String
    let symbol: String
    /// What the action works on, when seeing it helps choose, such as the text a copy puts on the
    /// clipboard.
    let detail: String?

    init(_ action: Item.Action) {
        let named: (title: String, symbol: String, detail: String?)
        switch action {
        case .open(let url, _):
            let web = url.scheme == "http" || url.scheme == "https"
            named = (web ? "Open in Browser" : "Open", "arrow.up.forward.app", nil)
        case .copy(let text, _):
            named = ("Copy", "doc.on.doc", text)
        case .paste(let text, _):
            named = ("Paste", "doc.on.clipboard", text)
        case .reveal:
            named = ("Show in Finder", "folder", nil)
        case .detail:
            named = ("Show Details", "doc.text", nil)
        case .run:
            named = ("Run", "play", nil)
        case .command:
            named = ("Run", "command", nil)
        }
        // A source's own title wins; the value stays visible either way.
        (title, symbol, detail) = (action.title ?? named.title, named.symbol, named.detail)
    }

    /// The shortcut that runs the action at `position` in an item's actions without the panel.
    static func shortcut(at position: Int) -> String? {
        switch position {
        case 0: "↩"
        case 1: "⌘↩"
        default: nil
        }
    }
}

/// The open action panel: the item it was opened on, its filter and the selected row.
struct ActionMenu {
    struct Row: Identifiable {
        /// Position in the item's actions.
        let id: Int
        let action: Item.Action
        let presentation: ActionPresentation
    }

    /// Captured on opening, so a late result never changes what the panel runs.
    let item: Item
    var filter = "" {
        didSet { if filter != oldValue { selection = 0 } }
    }
    /// Index into `rows`.
    private(set) var selection = 0

    /// The item's actions whose title matches the filter.
    var rows: [Row] {
        let query = Fold.query(filter)
        return item.actions.enumerated()
            .map { Row(id: $0.offset, action: $0.element, presentation: ActionPresentation($0.element)) }
            .filter { query.isEmpty || FuzzyMatcher.score(query, SearchKey($0.presentation.title)) != nil }
    }

    var selectedRow: Row? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    mutating func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}
