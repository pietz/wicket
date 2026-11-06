import Foundation

/// A running app, as captured when the palette was summoned.
public struct RunningApp: Sendable, Hashable {
    public var processID: Int32
    public var bundleID: String?

    public init(processID: Int32, bundleID: String?) {
        self.processID = processID
        self.bundleID = bundleID
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

/// What a pushed frame shows: `RunResult`'s content cases.
public enum Screen: Sendable, Hashable {
    /// One item, shown large.
    case answer(Item)
    /// Items in the producer's order.
    case list([Item])
    case detail(Detail)
}

/// What the palette does after an action ran.
public enum ActionOutcome: Sendable, Hashable {
    /// Hide the palette, then show the message briefly.
    case close(message: String?)
    /// Push a frame. A failure is pushed as a detail saying what went wrong.
    case push(Screen)
    /// Re-run the view the user is looking at, keeping its text, and show the message briefly.
    case reload(message: String?)
    /// Leave the palette as it is.
    case stay
}

/// The side effects actions have outside the palette, injected so the dispatcher's mapping is
/// testable. The app implements them with AppKit and `Extensions`.
@MainActor
public protocol ActionEffects {
    func open(_ url: URL)
    func copy(_ text: String)
    /// Types `text` into `app`, the app the user came from.
    func paste(_ text: String, into app: RunningApp?)
    func reveal(_ url: URL)
    func openSettings()
    func quit()
    /// Runs an extension command for an item's `run` action, which is never resent to a fresh
    /// process. Throws for an error response or a host failure.
    func run(_ invocation: Invocation) async throws -> RunResult
}

/// Turns an action and its context into an outcome: the one place where activating something
/// reaches past the palette. `run` actions resolve through the command registry, so built-ins and
/// extension commands are invoked the same way, by `CommandID`.
@MainActor
public struct ActionDispatcher {
    private let registry: CommandRegistry
    private let effects: any ActionEffects

    public init(registry: CommandRegistry, effects: any ActionEffects) {
        self.registry = registry
        self.effects = effects
    }

    public func perform(_ action: Item.Action, in context: ActionContext) async -> ActionOutcome {
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
            return .push(.detail(detail))
        case .run(let id, let args, _):
            return await run(Invocation(command: id, args: args))
        }
        return .close(message: nil)
    }

    private func run(_ invocation: Invocation) async -> ActionOutcome {
        guard let command = registry.command(invocation.command) else {
            return Self.failure(
                "Command Not Found", "This command isn't installed any more.", command: invocation.command)
        }
        switch command.id.owner {
        case .builtin:
            switch BuiltinCommand(rawValue: command.id.name) {
            case .settings: effects.openSettings()
            case .quit: effects.quit()
            case nil:
                return Self.failure(command.title, "Wicket has no such command.", command: command.id)
            }
            return .close(message: nil)
        case .extension:
            do {
                return Self.outcome(of: try await effects.run(invocation))
            } catch is CancellationError {
                return .stay
            } catch {
                return Self.failure("\(command.title) Failed", String(describing: error), command: command.id)
            }
        }
    }

    /// A `run` action's result: content is pushed as a new frame, `close` and `reload` act on the
    /// palette (docs/extensions.md).
    static func outcome(of result: RunResult) -> ActionOutcome {
        switch result {
        case .answer(let item): .push(.answer(item))
        case .list(let items): .push(.list(items))
        case .detail(let detail): .push(.detail(detail))
        case .close(let message): .close(message: message)
        case .reload(let message): .reload(message: message)
        }
    }

    /// A failure the user sees, as a detail they can copy (Return) and leave (Escape).
    static func failure(_ title: String, _ message: String, command: CommandID) -> ActionOutcome {
        let name =
            switch command.owner {
            case .builtin: command.name
            case .extension(let id): "\(id)/\(command.name)"
            }
        return .push(
            .detail(Detail(title: title, markdown: message, metadata: [.init(label: "Command", value: name)]))
        )
    }
}
