import Foundation

/// Who made a screen, which decides what it may show and what its actions may do (`ActionPolicy`).
/// Stamped on a screen when it is decoded (`WireContext.authority`), carried by its frame, inherited
/// by the pages it pushes, and handed to the dispatcher with every action (`ActionTarget`).
public enum Authority: Sendable, Hashable {
    /// Wicket's own screens and the actions it derives or adds (a file's Reveal, Follow Up).
    case host
    /// An extension's output, from the revision that sent it (nil where none is known, as in tests);
    /// its `run` actions are bound to that revision.
    case `extension`(ExtensionRevision?)
    /// An agent's reply: untrusted, since a prompt injection can steer it, so it only presents.
    case agent
}

/// The one table of what each authority may send and what its actions do when activated. Decoding
/// checks what is sent (every action, nested ones included, since each is decoded with the
/// sender's authority); the dispatcher checks again at activation, so an action that reached a
/// screen some other way, or one the host derived, still runs only what the table allows.
public enum ActionPolicy {
    /// The screens and done results each authority may send. Root mode narrows an extension's
    /// further (answer and list).
    public static func screens(from authority: Authority) -> [RunResult.Kind] {
        switch authority {
        case .host, .extension: RunResult.Kind.allCases
        case .agent: [.answer, .list, .detail]
        }
    }

    /// The actions each authority may send. `reveal` is the host's: it derives it for file
    /// subjects, so it runs under every authority but no producer sends it.
    public static func actions(from authority: Authority) -> [Item.Action.Kind] {
        switch authority {
        case .host: Item.Action.Kind.allCases
        case .extension: [.open, .copy, .paste, .detail, .run]
        case .agent: [.open, .copy, .detail]
        }
    }

    /// What activating an action does.
    public enum Resolution: Sendable, Hashable {
        /// Run this action: the one activated, or what it was rewritten to.
        case perform(Item.Action)
        /// Run nothing, and say why.
        case refuse(String)
    }

    /// What activating `action` under `authority` runs. An agent's `open` is followed like a link in
    /// a page (`Item.Action.following`): web, mail and files open, anything that would run (an app,
    /// a script) is revealed, other links are refused; its `paste` and `run` are refused. A reveal
    /// of something that isn't there any more reveals its folder. `inspect` says what a file is, nil
    /// if there's none.
    public static func resolve(
        _ action: Item.Action, as authority: Authority, home: URL, inspect: (URL) -> LinkedFile?
    ) -> Resolution {
        guard action.kind == .reveal || actions(from: authority).contains(action.kind) else {
            return .refuse(refusal(action.kind))
        }
        switch action {
        case .open(let url, let title) where authority == .agent:
            guard let followed = Item.Action.following(url, home: home, inspect: inspect) else {
                return .refuse("Wicket opens only web, mail and file links")
            }
            // A rewrite to Reveal drops the producer's title, so the panel names what really happens.
            if case .open(let url, nil) = followed { return .perform(.open(url: url, title: title)) }
            return .perform(followed)
        case .reveal(let url, let title) where url.isFileURL && inspect(url) == nil:
            return .perform(.reveal(url: url.deletingLastPathComponent(), title: title))
        default:
            return .perform(action)
        }
    }

    private static func refusal(_ kind: Item.Action.Kind) -> String {
        switch kind {
        case .paste: "An agent's reply can't paste"
        case .run: "An agent's reply can't run commands"
        default: "An agent's reply can't do that"
        }
    }
}
