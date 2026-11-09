import Foundation

extension CommandID {
    public static let runShell = CommandID.builtin("run-shell")
    public static let runInTerminal = CommandID.builtin("run-in-terminal")
}

/// The explicit shell prefix owns the root query, without starting a process on a keystroke.
public enum ShellCommand {
    public static func text(in query: String, prefix: String) -> String? {
        guard Settings.Shell.validPrefix(prefix), query.hasPrefix(prefix) else { return nil }
        return String(query.dropFirst(prefix.count).drop(while: { $0 == " " || $0 == "\t" }))
    }

    public static func item(text: String, settings: Settings.Shell) -> Item {
        let inline = Item.Action.run(command: .runShell, text: text, title: "Run in Wicket")
        let terminal = Item.Action.run(command: .runInTerminal, text: text, title: "Run in Terminal")
        let actions = settings.destination == .wicket ? [inline, terminal] : [terminal, inline]
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Item(
            id: "shell:run", title: empty ? "Run Shell Command" : text,
            subtitle: empty
                ? "Type a command to run" : "From your home folder · ⌘↩ for the other destination",
            icon: .symbol(name: "terminal"),
            accessory: settings.destination == .wicket ? "Wicket" : "Terminal",
            relevance: .answer, actions: empty ? [] : actions)
    }
}
