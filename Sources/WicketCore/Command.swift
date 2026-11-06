import Foundation

/// The identity of something the user can invoke: a built-in command or an extension's command.
/// Persistent bindings and item origins store this, never a row id.
public struct CommandID: Hashable, Codable, Sendable {
    public enum Owner: Hashable, Codable, Sendable {
        case builtin
        case `extension`(id: String)
    }

    public var owner: Owner
    /// The command's id within its owner, such as a manifest command id.
    public var name: String

    public init(owner: Owner, name: String) {
        self.owner = owner
        self.name = name
    }

    /// A command of the extension `id`.
    public static func `extension`(_ id: String, _ name: String) -> CommandID {
        CommandID(owner: .extension(id: id), name: name)
    }
}

extension CommandID {
    /// One of Wicket's own commands (`BuiltinCommand`).
    public static func builtin(_ name: String) -> CommandID {
        CommandID(owner: .builtin, name: name)
    }
}

/// The canonical spelling, used wherever a command is named in text: settings.json keys
/// (`"commands": {"builtin:ask-ai": …}`), logs, and the prefix of the item ids an extension's
/// command produces ("ext:github/search:pr-12"). `builtin:<name>` for Wicket's own commands,
/// `ext:<extension>/<command>` for an extension's. Every part is a slug, so the separators can't
/// appear inside one and the spelling round-trips.
extension CommandID: LosslessStringConvertible {
    public var description: String {
        switch owner {
        case .builtin: "builtin:\(name)"
        case .extension(let id): "ext:\(id)/\(name)"
        }
    }

    /// Parses the canonical spelling; nil for anything else (other separators, upper case, spaces).
    public init?(_ description: String) {
        if let name = description.wholeMatch(of: /builtin:([^\/:]+)/)?.1, Manifest.isSlug(String(name)) {
            self = .builtin(String(name))
        } else if let match = description.wholeMatch(of: /ext:([^\/:]+)\/([^\/:]+)/),
            Manifest.isSlug(String(match.1)), Manifest.isSlug(String(match.2))
        {
            self = .extension(String(match.1), String(match.2))
        } else {
            return nil
        }
    }
}

/// A command with what to run it on: the shape persistent bindings (hotkeys, aliases, deeplinks)
/// store, and what a `run` action becomes.
public struct Invocation: Hashable, Sendable {
    public var command: CommandID
    /// What the user typed for it; `""` for a `run` action.
    public var text: String
    /// Passed through from a `run` action.
    public var args: [String: JSONValue]?

    public init(command: CommandID, text: String = "", args: [String: JSONValue]? = nil) {
        self.command = command
        self.text = text
        self.args = args
    }
}

/// Whether a request may be resent to a fresh process when the one that had it exits cleanly.
public enum RequestKind: Sendable, Equatable, Hashable {
    /// Search text for a root, live or once command: reading only, so resending it is safe.
    case query
    /// A command run by an item's `run` action. It may have changed something before the process
    /// exited, so it is never resent.
    case action
}

/// A command to show in a frame: the command, what to run it on, and how its first run counts.
/// A command frame runs `invocation` on open and on reload (a live command with the frame's query
/// as its text); a live command's searches are always queries.
public struct CommandRun: Sendable, Hashable {
    public var command: RegisteredCommand
    public var invocation: Invocation
    public var kind: RequestKind

    public init(command: RegisteredCommand, invocation: Invocation, kind: RequestKind) {
        self.command = command
        self.invocation = invocation
        self.kind = kind
    }
}

/// Produces what a command frame shows. Each element of the stream replaces the frame's content,
/// the same rule as `ResultSource.updates`: an extension command yields one result, a streaming
/// producer (an AI answer) yields a growing detail again and again. `close` closes the palette and
/// `reload` goes back to the frame the command was opened from and runs that again. Cancelling the
/// iteration (the frame was popped, the palette dismissed, the query superseded) must stop the work.
@MainActor
public protocol CommandRunner: AnyObject {
    func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error>
}

/// The one runner the palette session gets: each run goes to its command's owner, built-ins to the
/// runner registered for them (Ask AI), extension commands to the extensions' runner.
@MainActor
public final class CommandRouter: CommandRunner {
    private let builtins: [CommandID: any CommandRunner]
    private let extensions: (any CommandRunner)?

    public init(builtins: [CommandID: any CommandRunner], extensions: (any CommandRunner)?) {
        self.builtins = builtins
        self.extensions = extensions
    }

    public func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error>
    {
        let runner =
            switch invocation.command.owner {
            case .builtin: builtins[invocation.command]
            case .extension: extensions
            }
        guard let runner else {
            return AsyncThrowingStream { $0.finish(throwing: Unrouted()) }
        }
        return runner.run(invocation, kind: kind)
    }

    /// A command nothing runs, such as a built-in without a runner.
    struct Unrouted: Error, CustomStringConvertible {
        var description: String { "Nothing runs this command." }
    }
}
