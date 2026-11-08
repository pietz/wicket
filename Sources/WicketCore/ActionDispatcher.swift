import Foundation

/// A running app, as captured when the palette was summoned.
public struct RunningApp: Sendable, Hashable {
    public var processID: Int32
    public var bundleID: String?
    /// Its display name, for "Paste to Mail" and the paste messages.
    public var name: String?

    public init(processID: Int32, bundleID: String?, name: String? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.name = name
    }
}

/// What an action runs in.
public struct ActionContext: Sendable, Hashable {
    /// The app that was frontmost when the palette was summoned: where `paste` types.
    public var previousApp: RunningApp?

    public init(previousApp: RunningApp? = nil) {
        self.previousApp = previousApp
    }
}

/// What the palette does after an action ran.
public enum ActionOutcome: Sendable, Hashable {
    /// Hide the palette.
    case close
    /// Push a detail frame: a `detail` action, with the authority of the screen it came from, or a
    /// failure saying what went wrong (the host's).
    case push(Detail, Authority)
    /// Show a command in its own frame, fed by its run (`PaletteSession.open`).
    case open(CommandRun)
    /// Nothing ran, since the action's authority doesn't allow it (`ActionPolicy`); the text says why.
    case refused(String)
}

/// The side effects actions have outside the palette, injected so the dispatcher's mapping is
/// testable. The app implements them with AppKit and `Extensions`.
@MainActor
public protocol ActionEffects {
    func open(_ url: URL)
    func copy(_ text: String)
    /// Types `text` into `app`, the app the user came from, once the palette has closed (`PastePlan`);
    /// when it can't, the text is copied and a message says why.
    func paste(_ text: String, into app: RunningApp?)
    func reveal(_ url: URL)
    /// What a file is, with symlinks resolved; nil if nothing is there. `ActionPolicy` asks it.
    func inspect(_ file: URL) -> LinkedFile?
}

/// Turns an action and its context into an outcome: the one place where activating something
/// reaches past the palette. `run` actions resolve through the command registry, so built-ins and
/// extension commands are invoked the same way, by `CommandID`, and what a command does with its
/// text comes from the one invocation policy (`CommandRun`). Every
/// command opens its frame, whose run the palette session owns; one that just does something (Settings,
/// Quit) answers `close`, which takes that frame off again as the palette closes. What the host does for the user is a built-in reached
/// by `run`, so `Item.Action` gains no cases for it. Every action runs under an authority, and
/// `ActionPolicy` decides what it may do first, so an agent's reply never runs anything whatever
/// reached the screen.
@MainActor
public struct ActionDispatcher {
    private let registry: CommandRegistry
    private let effects: any ActionEffects
    /// Where `~` links lead.
    private let home: URL

    public init(
        registry: CommandRegistry, effects: any ActionEffects,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.registry = registry
        self.effects = effects
        self.home = home
    }

    /// Runs the target's action at `position` under its authority; nil if there is no such action.
    public func perform(
        _ target: ActionTarget, at position: ActionTarget.Position, in context: ActionContext
    ) -> ActionOutcome? {
        target.action(at: position).map { perform($0.action, as: $0.authority, in: context) }
    }

    /// What activating `action` under `authority` would run (`ActionPolicy.resolve`), so the action
    /// panel and the footer can name it: an agent's Open of a script is a Reveal.
    public func resolve(_ action: Item.Action, as authority: Authority) -> ActionPolicy.Resolution {
        ActionPolicy.resolve(action, as: authority, home: home, inspect: effects.inspect)
    }

    public func perform(_ action: Item.Action, as authority: Authority, in context: ActionContext)
        -> ActionOutcome
    {
        let resolved: Item.Action
        switch resolve(action, as: authority) {
        case .perform(let action): resolved = action
        case .refuse(let reason): return .refused(reason)
        }
        switch resolved {
        case .open(let url, _):
            effects.open(url)
        case .copy(let text, _):
            effects.copy(text)
        case .paste(let text, _):
            effects.paste(text, into: context.previousApp)
        case .reveal(let url, _):
            effects.reveal(url)
        case .detail(let detail):
            return .push(detail, authority)
        case .run(let id, let text, let args, _, let revision):
            return run(id, text: text, args: args, revision: revision)
        }
        return .close
    }

    private func run(
        _ id: CommandID, text: String, args: [String: JSONValue]?, revision: ExtensionRevision?
    ) -> ActionOutcome {
        guard let command = registry.command(id) else {
            return .push(
                .failure("Command Not Found", "This command isn't installed any more.", command: id), .host)
        }
        return .open(CommandRun(command, .invoked, text: text, args: args, revision: revision))
    }
}
