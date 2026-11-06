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
