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
