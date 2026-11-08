import AppKit
import WicketCore

/// How an action is named and drawn in the actions menu and the footer: the one place to extend
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

/// The actions menu (⌘K), a native `NSMenu` built from the target captured on opening, so a late
/// result never changes what it runs: the target's actions, then the screen's own under a section
/// header named after the screen ("Answer"), each named as it runs, with ↩ and ⌘↩ shown on the
/// actions those chords run. It only records the choice (`chosen`); the controller runs it through
/// the dispatcher once the menu has closed.
@MainActor
final class ActionMenu: NSObject {
    let menu = NSMenu()
    let target: ActionTarget
    /// The position of each action item, in menu order.
    private(set) var positions: [ActionTarget.Position] = []
    private(set) var chosen: ActionTarget.Position?

    /// `present` names an action under the authority it runs as.
    init(
        target: ActionTarget, screenTitle: String = "Screen",
        present: (Item.Action, Authority) -> ActionPresentation = { action, _ in ActionPresentation(action) }
    ) {
        self.target = target
        super.init()
        menu.autoenablesItems = false
        for (index, action) in target.actions.enumerated() {
            add(.action(index), present(action, target.authority))
        }
        guard !target.screen.isEmpty else { return }
        if !target.actions.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: screenTitle))
        for (index, action) in target.screen.enumerated() {
            add(.screen(index), present(action, .host))
        }
    }

    private func add(_ position: ActionTarget.Position, _ presentation: ActionPresentation) {
        let item = NSMenuItem(title: presentation.title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.tag = positions.count
        item.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        item.subtitle = presentation.detail.flatMap(Self.subtitle)
        if position == target.primary || position == target.secondary {
            item.keyEquivalent = "\r"
            item.keyEquivalentModifierMask = position == target.primary ? [] : .command
        }
        positions.append(position)
        menu.addItem(item)
    }

    /// A detail's first line, cut short: a copied text can be long.
    static func subtitle(_ detail: String) -> String? {
        let line = detail.prefix { !$0.isNewline }
        guard !line.isEmpty else { return nil }
        return line.count > 60 || line.count < detail.count ? line.prefix(60) + "…" : String(line)
    }

    @objc private func choose(_ item: NSMenuItem) {
        chosen = positions[item.tag]
    }
}
