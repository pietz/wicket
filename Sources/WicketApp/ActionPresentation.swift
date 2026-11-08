import WicketCore

/// How an action is named and drawn in the action panel and the footer: the one place to extend
/// when `Item.Action` gains cases or titles.
struct ActionPresentation {
    var title: String
    var symbol: String
    /// What the action works on, when seeing it helps choose, such as the text a copy puts on the
    /// clipboard.
    var detail: String?

    /// `pasteTarget` is the app a paste types into, if known, so a plain paste reads "Paste to Mail".
    init(_ action: Item.Action, pasteTarget: String? = nil) {
        let named: (title: String, symbol: String, detail: String?)
        switch action {
        case .open(let url, _):
            let web = url.scheme == "http" || url.scheme == "https"
            named = (web ? "Open in Browser" : "Open", "arrow.up.forward.app", nil)
        case .copy(let text, _):
            named = ("Copy", "doc.on.doc", text)
        case .paste(let text, _):
            named = (pasteTarget.map { "Paste to \($0)" } ?? "Paste", "doc.on.clipboard", text)
        case .reveal:
            named = ("Show in Finder", "folder", nil)
        case .detail:
            named = ("Show Details", "doc.text", nil)
        case .run(let command, _, _, _, _):
            named = ("Run", command.owner == .builtin ? "command" : "play", nil)
        }
        // A source's own title wins; the value stays visible either way.
        (title, symbol, detail) = (action.title ?? named.title, named.symbol, named.detail)
    }

    /// `action` as activating it really runs it (`resolved`, from `ActionPolicy`): an agent's Open of
    /// a script is a Reveal, which names the file it reveals, since the rewrite drops the producer's
    /// title.
    init(_ action: Item.Action, resolved: ActionPolicy.Resolution, pasteTarget: String? = nil) {
        guard case .perform(let real) = resolved, real != action else {
            self.init(action, pasteTarget: pasteTarget)
            return
        }
        self.init(real, pasteTarget: pasteTarget)
        if case .reveal(let url, _) = real { detail = url.lastPathComponent }
    }
}

/// The open action panel: what it was opened on (the selected item, or a detail), its filter and
/// the selected row. The target's actions come first, then the screen's own as a group.
struct ActionMenu {
    struct Row: Identifiable {
        /// Where the action is in the target.
        let id: ActionTarget.Position
        let presentation: ActionPresentation
    }

    /// Captured on opening, so a late result never changes what the panel runs.
    let target: ActionTarget
    /// The screen group's title: "Answer" on an agent's screen.
    let screenTitle: String
    /// Every action, named as it runs.
    private let all: [Row]
    var filter = "" {
        didSet { if filter != oldValue { selection = 0 } }
    }
    /// Index into `rows`.
    private(set) var selection = 0

    /// `present` names an action under the authority it runs as.
    init(
        target: ActionTarget, screenTitle: String = "Screen",
        present: (Item.Action, Authority) -> ActionPresentation = { action, _ in ActionPresentation(action) }
    ) {
        self.target = target
        self.screenTitle = screenTitle
        let actions = target.actions.enumerated().map {
            Row(id: .action($0.offset), presentation: present($0.element, target.authority))
        }
        let screen = target.screen.enumerated().map { index, action in
            var presentation = present(action, .host)
            if ReadSummary.is(action) { presentation.title = ReadSummary.title }
            return Row(id: .screen(index), presentation: presentation)
        }
        all = actions + screen
    }

    /// The lines the panel has unfiltered: its actions and the screen group's title. The card makes
    /// room for them all, so filtering never moves it.
    var lineCount: Int { all.count + (target.screen.isEmpty ? 0 : 1) }

    /// The actions whose title matches the filter.
    var rows: [Row] {
        let query = Fold.query(filter)
        guard !query.isEmpty else { return all }
        return all.filter { FuzzyMatcher.score(query, SearchKey($0.presentation.title)) != nil }
    }

    var selectedRow: Row? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// The chord that runs the action at `position` without the panel: Return the first, ⌘↩ the
    /// target's secondary.
    func shortcut(for position: ActionTarget.Position) -> String? {
        if position == .action(0) { return "↩" }
        return position == target.secondary ? "⌘↩" : nil
    }

    mutating func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}
