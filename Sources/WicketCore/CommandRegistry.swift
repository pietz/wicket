import Foundation

/// Wicket's own commands. Each is registered as `CommandID.builtin(rawValue)` and runs through the
/// action dispatcher like any other command.
public enum BuiltinCommand: String, CaseIterable, Sendable {
    case settings, quit

    public var id: CommandID { .builtin(rawValue) }

    public var registered: RegisteredCommand {
        switch self {
        case .settings: RegisteredCommand(id: id, title: "Wicket Settings", icon: .symbol(name: "gearshape"))
        case .quit: RegisteredCommand(id: id, title: "Quit Wicket", icon: .symbol(name: "power"))
        }
    }
}

/// One entry of the command registry: what the root search lists and what a keyword, an id (and
/// later a hotkey, alias, deeplink or MCP call) resolves to.
public struct RegisteredCommand: Sendable, Hashable, Identifiable {
    public var id: CommandID
    public var title: String
    public var subtitle: String?
    public var icon: Item.Icon
    /// One word; typing it and a space in the root search opens the command's frame. Matched
    /// ignoring case, and only for listed commands.
    public var keyword: String?
    /// Whether the root search lists it. Hidden commands and root-mode extension commands are
    /// reachable by id only.
    public var isListed: Bool
    /// How its frame runs it: `once` runs it when opened (a list is then filtered locally), `live`
    /// runs it again for every change of the frame's text. Built-ins are `once`.
    public var mode: Manifest.Command.Mode
    /// The search field's hint in a live command's frame.
    public var placeholder: String?

    public init(
        id: CommandID, title: String, subtitle: String? = nil, icon: Item.Icon, keyword: String? = nil,
        isListed: Bool = true, mode: Manifest.Command.Mode = .once, placeholder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keyword = keyword
        self.isListed = isListed
        self.mode = mode
        self.placeholder = placeholder
    }

    /// A command from an extension's manifest; `icon` is the command's, else the extension's.
    public init(extension extensionID: String, command: Manifest.Command, icon: Item.Icon?) {
        self.init(
            id: .extension(extensionID, command.id), title: command.title, subtitle: command.subtitle,
            icon: icon ?? .symbol(name: "puzzlepiece.extension"), keyword: command.keyword,
            isListed: !command.hidden && command.mode != .root, mode: command.mode,
            placeholder: command.placeholder)
    }
}

/// The one catalog of invocable commands: Wicket's built-ins and the commands of installed
/// extensions, keyed by `CommandID`. The root search lists it (`CommandsSource`), the action
/// dispatcher resolves `run` actions through it, and keywords resolve here; per-command hotkeys,
/// aliases, deeplinks, the fallback list and the MCP server are meant to resolve here too, storing a
/// `CommandID` or an `Invocation`, never a row id.
///
/// Keyword collisions: a built-in always keeps its keyword; among extensions the first in registry
/// order wins (extension id, then manifest order, as `Extensions.commands` lists them), so the
/// winner never depends on install or load order. Each loser keeps its other ways in (search, id)
/// and is reported in `keywordConflicts`.
@MainActor
public final class CommandRegistry {
    /// A keyword claimed by more than one command: `winner` gets it, `loser` doesn't.
    public struct KeywordConflict: Sendable, Hashable {
        public var keyword: String
        public var winner: CommandID
        public var loser: CommandID
    }

    /// Built-ins first, then extension commands in the order given.
    public private(set) var commands: [RegisteredCommand] = []
    public private(set) var keywordConflicts: [KeywordConflict] = []
    private let builtins: [RegisteredCommand]
    private var byID: [CommandID: RegisteredCommand] = [:]
    private var byKeyword: [String: CommandID] = [:]
    private var index = SearchIndex([])

    public init(builtins: [RegisteredCommand] = BuiltinCommand.allCases.map(\.registered)) {
        self.builtins = builtins
        rebuild(extensions: [])
    }

    /// Replaces every extension command, for when extensions were loaded or changed. Entries owned
    /// by `.builtin` are ignored: an extension can't take a built-in's identity.
    public func setExtensionCommands(_ commands: [RegisteredCommand]) {
        rebuild(
            extensions: commands.filter {
                if case .extension = $0.id.owner { true } else { false }
            })
    }

    public func command(_ id: CommandID) -> RegisteredCommand? {
        byID[id]
    }

    public func command(keyword: String) -> RegisteredCommand? {
        byKeyword[keyword.lowercased()].flatMap { byID[$0] }
    }

    /// The listed commands matching `text` as root items (all of them for an empty text). A keyword
    /// matches as an alternate name.
    public func search(_ text: String) -> [Item] {
        index.search(text)
    }

    /// The root item id of a command, stable across launches so frecency follows it:
    /// "commands:quit", "commands:github/search".
    public static func itemID(for id: CommandID) -> String {
        switch id.owner {
        case .builtin: "commands:\(id.name)"
        case .extension(let owner): "commands:\(owner)/\(id.name)"
        }
    }

    private func rebuild(extensions: [RegisteredCommand]) {
        commands = []
        byID = [:]
        byKeyword = [:]
        keywordConflicts = []
        for command in builtins + extensions where byID[command.id] == nil {
            commands.append(command)
            byID[command.id] = command
            // A hidden command is reachable by `run` actions only (docs/extensions.md).
            guard command.isListed, let keyword = command.keyword?.lowercased() else { continue }
            if let winner = byKeyword[keyword] {
                keywordConflicts.append(KeywordConflict(keyword: keyword, winner: winner, loser: command.id))
            } else {
                byKeyword[keyword] = command.id
            }
        }
        index = SearchIndex(
            commands.filter(\.isListed).map { command in
                let item = Item(
                    id: Self.itemID(for: command.id), title: command.title, subtitle: command.subtitle,
                    icon: command.icon, accessory: "Command", actions: [.run(command: command.id)])
                return (item, command.keyword.map { [$0] } ?? [])
            })
    }
}

/// The registry's listed commands in the root search.
@MainActor
public struct CommandsSource: ResultSource {
    public let id = "commands"
    private let registry: CommandRegistry

    public init(_ registry: CommandRegistry) {
        self.registry = registry
    }

    public func instant(_ query: Query) -> [Item] {
        registry.search(query.text)
    }
}
