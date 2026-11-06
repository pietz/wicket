import Foundation

/// The global hotkeys settings.json binds to commands (`Settings.commands`), checked before any is
/// registered with the system. A binding is active only for a registered command: one for a command
/// that isn't (an extension not installed, or not allowed in the palette yet) waits, inert, and
/// takes no key from anyone. Collisions are rejected with a reason, never resolved by file order:
/// - the palette's own hotkey always wins, so Wicket can always be summoned;
/// - between commands, the first in canonical id order keeps the hotkey (`builtin:` before `ext:`,
///   the rule keywords and aliases follow).
public enum CommandHotkeys {
    /// A binding that won't be registered, and why.
    public struct Rejection: Sendable, Hashable, CustomStringConvertible {
        public enum Reason: Sendable, Hashable {
            /// It is the palette's hotkey.
            case palette
            /// An earlier command has it.
            case taken(by: CommandID)
        }

        public var command: CommandID
        public var hotkey: Shortcut
        public var reason: Reason

        public var description: String {
            switch reason {
            case .palette: "commands.\(command).hotkey \(hotkey) is the palette's hotkey; ignoring it"
            case .taken(let other): "commands.\(command).hotkey \(hotkey) is already \(other)'s; ignoring it"
            }
        }
    }

    /// The hotkeys to register, each with its command, and the bindings rejected.
    public static func resolve(
        _ commands: [CommandID: CommandBinding], palette: Shortcut, isRegistered: (CommandID) -> Bool
    ) -> (hotkeys: [Shortcut: CommandID], rejected: [Rejection]) {
        var hotkeys: [Shortcut: CommandID] = [:]
        var rejected: [Rejection] = []
        let bound = commands.compactMap { id, binding in binding.hotkey.map { (id, $0) } }
            .filter { isRegistered($0.0) }
            .sorted { $0.0.description < $1.0.description }
        for (id, hotkey) in bound {
            if hotkey == palette {
                rejected.append(Rejection(command: id, hotkey: hotkey, reason: .palette))
            } else if let owner = hotkeys[hotkey] {
                rejected.append(Rejection(command: id, hotkey: hotkey, reason: .taken(by: owner)))
            } else {
                hotkeys[hotkey] = id
            }
        }
        return (hotkeys, rejected)
    }
}
