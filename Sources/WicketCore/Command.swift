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
