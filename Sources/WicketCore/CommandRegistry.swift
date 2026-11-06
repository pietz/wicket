import Foundation

/// Wicket's own commands. Each is registered as `CommandID.builtin(rawValue)` and runs through the
/// action dispatcher like any other command.
public enum BuiltinCommand: String, CaseIterable, Sendable {
    case settings, quit
    /// Answers a question with the user's agent CLI in its own frame (`AskAI`).
    case askAI = "ask-ai"

    public var id: CommandID { .builtin(rawValue) }

    public var registered: RegisteredCommand {
        switch self {
        case .settings:
            RegisteredCommand(
                id: id, title: "Wicket Settings", icon: .symbol(name: "gearshape"), input: .none)
        case .quit:
            RegisteredCommand(id: id, title: "Quit Wicket", icon: .symbol(name: "power"), input: .none)
        case .askAI: AskAI.registered
        }
    }
}

/// One entry of the command registry: what the root search lists and what a keyword, an id, an
/// alias, a hotkey (and later a deeplink or MCP call) resolves to. How it takes text and whether a
/// run may be resent are the command's own declarations; `CommandRun(_:_:text:args:)` applies them
/// the same way for every way in.
public struct RegisteredCommand: Sendable, Hashable, Identifiable {
    public var id: CommandID
    public var title: String
    public var subtitle: String?
    public var icon: Item.Icon
    /// One word; typing it and a space in the root search opens the command's frame. Matched
    /// ignoring case, and only for commands the root offers (`isOffered`) that take text.
    public var keyword: String?
    /// Whether the root search lists it. Hidden commands and root-mode extension commands are
    /// reachable by id only.
    public var isListed: Bool
    public var input: CommandInput
    public var retry: RetryPolicy
    /// The search field's hint in its frame: a live command's, or one waiting for its text.
    public var placeholder: String?
    /// Offered as a row in the root's fallback tier for any query, which it is run on (`FallbackSource`).
    /// Only for `submitText` commands.
    public var isFallback: Bool
    /// The feature it belongs to: while that is off, the command isn't registered.
    public var feature: Feature?

    public init(
        id: CommandID, title: String, subtitle: String? = nil, icon: Item.Icon, keyword: String? = nil,
        isListed: Bool = true, input: CommandInput = .immediateText, retry: RetryPolicy = .never,
        placeholder: String? = nil, isFallback: Bool = false, feature: Feature? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keyword = keyword
        self.isListed = isListed
        self.input = input
        self.retry = retry
        self.placeholder = placeholder
        self.isFallback = isFallback
        self.feature = feature
    }

    /// A command from an extension's manifest; `icon` is the command's, else the extension's.
    public init(extension extensionID: String, command: Manifest.Command, icon: Item.Icon?) {
        self.init(
            id: .extension(extensionID, command.id), title: command.title, subtitle: command.subtitle,
            icon: icon ?? .symbol(name: "puzzlepiece.extension"), keyword: command.keyword,
            isListed: !command.hidden && command.mode != .root, input: command.input, retry: command.retry,
            placeholder: command.placeholder)
    }

    /// Whether the root offers it: listed, or a fallback. Only these have keywords, and the settings
    /// window offers bindings for them.
    public var isOffered: Bool { isListed || isFallback }
}

/// The manifest's modes in the domain's terms.
extension Manifest.Command {
    /// `once` (and `root`, should a `run` action name one) runs on its text when invoked; `live`
    /// searches as the user types.
    public var input: CommandInput {
        mode == .live ? .liveText : .immediateText
    }

    /// Live and root runs are searches, so they may be resent; a once command only if its manifest
    /// says it is `repeatable`.
    public var retry: RetryPolicy {
        mode != .once || repeatable ? .safeToRepeat : .never
    }
}

/// The one catalog of invocable commands: Wicket's built-ins and the commands of installed
/// extensions, keyed by `CommandID`. The root search lists it (`CommandsSource`), the action
/// dispatcher resolves `run` actions through it, and keywords and the user's aliases resolve here;
/// per-command hotkeys resolve their `CommandID` here too (`CommandHotkeys`), and deeplinks, the
/// fallback list and the MCP server are meant to, storing a `CommandID` or an `Invocation`, never a
/// row id.
///
/// Aliases (settings.json `commands`) are the user's own words for a command. Typed alone in the
/// root, an alias lists its command first (the `alias` tier, above every exact match); typed with a
/// space it works as the command's keyword (for an offered command that takes text). Matched
/// ignoring case. An alias of a command that isn't registered does nothing until it is.
///
/// Collisions, all resolved so the winner never depends on file, install or load order:
/// - Alias against alias: the command first in canonical id order (`builtin:` before `ext:`) keeps
///   it; the loser is in `aliasConflicts`.
/// - Alias against keyword: the alias wins, built-in keywords included; the keyword's command is a
///   loser in `keywordConflicts`.
/// - Keyword against keyword: a built-in always keeps its keyword; among extensions the first in
///   registry order wins (extension id, then manifest order, as `Extensions.commands` lists them).
/// Each loser keeps its other ways in (search, id, a hotkey).
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
    /// Aliases settings.json gives to more than one registered command.
    public private(set) var aliasConflicts: [KeywordConflict] = []
    /// Bumped on every change of what is registered, aliases included, so the app can tell whether
    /// a settings reload changed the catalog (and the root must search again).
    public private(set) var revision = 0
    private let builtins: [RegisteredCommand]
    private var extensions: [RegisteredCommand] = []
    /// Features that are off: their built-ins aren't registered until they are on again.
    private var disabledFeatures: Set<Feature> = []
    /// The aliases settings.json asks for, registered or not.
    private var requestedAliases: [CommandID: String] = [:]
    private var byID: [CommandID: RegisteredCommand] = [:]
    /// Lowercased alias to the command that has it; registered commands only.
    private var byAlias: [String: CommandID] = [:]
    private var aliasOf: [CommandID: String] = [:]
    private var byKeyword: [String: CommandID] = [:]
    private var index = SearchIndex([])

    public init(builtins: [RegisteredCommand] = BuiltinCommand.allCases.map(\.registered)) {
        self.builtins = builtins
        rebuild()
    }

    /// Replaces every extension command, for when extensions were loaded or changed. Entries owned
    /// by `.builtin` are ignored: an extension can't take a built-in's identity.
    public func setExtensionCommands(_ commands: [RegisteredCommand]) {
        extensions = commands.filter {
            if case .extension = $0.id.owner { true } else { false }
        }
        rebuild()
    }

    /// Unregisters the built-ins of the features in `disabled` and registers the rest again, for
    /// when settings.json turned a feature off or on. Their hotkeys and aliases wait, inert, like
    /// those of a command that isn't installed.
    public func setDisabledFeatures(_ disabled: Set<Feature>) {
        guard disabled != disabledFeatures else { return }
        disabledFeatures = disabled
        rebuild()
    }

    /// Replaces the user's aliases, for when settings.json was loaded or changed.
    public func setAliases(_ aliases: [CommandID: String]) {
        guard aliases != requestedAliases else { return }
        requestedAliases = aliases
        rebuild()
    }

    public func command(_ id: CommandID) -> RegisteredCommand? {
        byID[id]
    }

    /// The command whose keyword (or alias) `keyword` is, if typing it and a space opens its frame.
    /// A word that is someone's alias is never another command's keyword.
    public func command(keyword: String) -> RegisteredCommand? {
        byKeyword[keyword.lowercased()].flatMap { byID[$0] }
    }

    /// The command that has `alias`, ignoring case.
    public func command(alias: String) -> RegisteredCommand? {
        byAlias[alias.lowercased()].flatMap { byID[$0] }
    }

    /// The alias `id` has in effect: the user's, unless another command won it. Nil for a command
    /// that isn't registered.
    public func alias(of id: CommandID) -> String? {
        aliasOf[id]
    }

    /// The listed commands matching `text` as root items (all of them for an empty text). A keyword
    /// or an alias matches as an alternate name, and the text being exactly an alias puts its command
    /// in the `alias` tier.
    public func search(_ text: String) -> [Item] {
        var items = index.search(text)
        let word = text.trimmingCharacters(in: .whitespaces)
        if !word.isEmpty, let id = byAlias[word.lowercased()] {
            let itemID = Self.itemID(for: id)
            if let index = items.firstIndex(where: { $0.id == itemID }) { items[index].relevance = .alias }
        }
        return items
    }

    /// The root item id of a command, stable across launches so frecency follows it:
    /// "commands:quit", "commands:github/search".
    public static func itemID(for id: CommandID) -> String {
        switch id.owner {
        case .builtin: "commands:\(id.name)"
        case .extension(let owner): "commands:\(owner)/\(id.name)"
        }
    }

    private func rebuild() {
        revision += 1
        commands = []
        byID = [:]
        let builtins = builtins.filter { $0.feature.map { !disabledFeatures.contains($0) } ?? true }
        for command in builtins + extensions where byID[command.id] == nil {
            commands.append(command)
            byID[command.id] = command
        }

        byAlias = [:]
        aliasOf = [:]
        aliasConflicts = []
        let aliases = requestedAliases.filter { byID[$0.key] != nil }.sorted {
            $0.key.description < $1.key.description
        }
        for (id, alias) in aliases {
            let word = alias.lowercased()
            if let winner = byAlias[word] {
                aliasConflicts.append(KeywordConflict(keyword: word, winner: winner, loser: id))
            } else {
                byAlias[word] = id
                aliasOf[id] = alias
            }
        }

        byKeyword = [:]
        keywordConflicts = []
        // A hidden command is reachable by `run` actions only (docs/extensions.md), and one that
        // takes no text has no frame to open with it.
        let routed = commands.filter { $0.isOffered && $0.input != .none }
        for command in routed {
            if let alias = aliasOf[command.id]?.lowercased() { byKeyword[alias] = command.id }
        }
        for command in routed {
            guard let keyword = command.keyword?.lowercased() else { continue }
            if let winner = byAlias[keyword] ?? byKeyword[keyword] {
                if winner != command.id {
                    keywordConflicts.append(
                        KeywordConflict(keyword: keyword, winner: winner, loser: command.id))
                }
            } else {
                byKeyword[keyword] = command.id
            }
        }

        index = SearchIndex(
            commands.filter(\.isListed).map { command in
                let item = Item(
                    id: Self.itemID(for: command.id), title: command.title, subtitle: command.subtitle,
                    icon: command.icon, accessory: "Command", actions: [.run(command: command.id)])
                let alternates = [command.keyword, aliasOf[command.id]].compactMap { $0 }
                return (item, alternates)
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
