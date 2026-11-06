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
    /// Push a detail frame: a `detail` action, or a failure saying what went wrong.
    case push(Detail)
    /// Show a command in its own frame, fed by its run (`PaletteSession.open`).
    case open(CommandRun)
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
    func openSettings()
    func quit()
}

/// Turns an action and its context into an outcome: the one place where activating something
/// reaches past the palette. `run` actions resolve through the command registry, so built-ins and
/// extension commands are invoked the same way, by `CommandID`. Settings and Quit run their effect
/// here; every other command opens its frame, whose run the palette session owns.
@MainActor
public struct ActionDispatcher {
    private let registry: CommandRegistry
    private let effects: any ActionEffects

    public init(registry: CommandRegistry, effects: any ActionEffects) {
        self.registry = registry
        self.effects = effects
    }

    public func perform(_ action: Item.Action, in context: ActionContext) -> ActionOutcome {
        switch action {
        case .open(let url, _):
            effects.open(url)
        case .copy(let text, _):
            effects.copy(text)
        case .paste(let text, _):
            effects.paste(text, into: context.previousApp)
        case .reveal(let url, _):
            effects.reveal(url)
        case .detail(let detail):
            return .push(detail)
        case .run(let id, let args, _):
            return run(Invocation(command: id, args: args))
        }
        return .close
    }

    private func run(_ invocation: Invocation) -> ActionOutcome {
        guard let command = registry.command(invocation.command) else {
            return .push(
                .failure(
                    "Command Not Found", "This command isn't installed any more.", command: invocation.command
                ))
        }
        switch command.id.owner == .builtin ? BuiltinCommand(rawValue: command.id.name) : nil {
        case .settings:
            effects.openSettings()
            return .close
        case .quit:
            effects.quit()
            return .close
        case .askAI, nil:
            // Extension commands, and built-ins that show something (Ask AI): their frame runs them.
            let kind = Self.kind(of: invocation, command)
            return .open(CommandRun(command: command, invocation: invocation, kind: kind))
        }
    }

    /// Opening a listed command without `args` is the same as pressing Return on its row, a query;
    /// anything else a `run` action starts (a hidden command, or one given `args`) may change
    /// something, so it is an action and never resent (docs/extensions.md).
    static func kind(of invocation: Invocation, _ command: RegisteredCommand) -> RequestKind {
        command.isListed && invocation.args == nil ? .query : .action
    }
}
