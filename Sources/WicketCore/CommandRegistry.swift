import Foundation

/// One entry of the command registry: what the root search lists and what a keyword or an id (and
/// later a deeplink or MCP call) resolves to. How it takes text and whether a
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
    /// Alternate words and phrases for local search; these do not route keyword invocations.
    public var search: [String]
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
    /// The feature it belongs to: while that is off, the command isn't registered (a built-in's,
    /// from its table entry).
    public var feature: Feature?
    /// An extension command's: the active revision it was registered from, which a run of it binds
    /// to when it starts (`CommandRun`). Nil for built-ins.
    public var revision: ExtensionRevision?
    /// Whether its runs get the Finder selection at summon (`Invocation.context`): Run Agent.
    /// Any other command never sees it.
    public var usesContext: Bool

    public init(
        id: CommandID, title: String, subtitle: String? = nil, icon: Item.Icon, keyword: String? = nil,
        search: [String] = [], isListed: Bool = true, input: CommandInput = .immediateText,
        retry: RetryPolicy = .never,
        placeholder: String? = nil, isFallback: Bool = false, feature: Feature? = nil,
        revision: ExtensionRevision? = nil, usesContext: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keyword = keyword
        self.search = search
        self.isListed = isListed
        self.input = input
        self.retry = retry
        self.placeholder = placeholder
        self.isFallback = isFallback
        self.feature = feature
        self.revision = revision
        self.usesContext = usesContext
    }

    /// A command from an extension's manifest; `icon` is the command's, else the extension's;
    /// `revision` the active revision whose manifest it is.
    public init(
        extension extensionID: String, command: Manifest.Command, icon: Item.Icon?,
        revision: ExtensionRevision? = nil
    ) {
        self.init(
            id: .extension(extensionID, command.id), title: command.title, subtitle: command.subtitle,
            icon: icon ?? .symbol(name: "puzzlepiece.extension"), keyword: command.keyword,
            search: command.search,
            isListed: !command.hidden && command.mode != .root, input: command.input, retry: command.retry,
            placeholder: command.placeholder, revision: revision)
    }

    /// Whether the root offers it: listed, or a fallback. Only these have keywords.
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
/// dispatcher resolves `run` actions through it, and keywords resolve here; deeplinks and the MCP
/// server are meant to, storing a `CommandID` or an `Invocation`, never a row id.
///
/// Keyword collisions are resolved so the winner never depends on install or load order: a
/// built-in always keeps its keyword; among extensions the first in registry order wins (extension
/// id, then manifest order, as `Extensions.commands` lists them). A loser keeps its other ways in
/// (search, its id).
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
    /// Bumped on every change of what is registered, so the app can tell whether
    /// a settings reload changed the catalog (and the root must search again).
    public private(set) var changes = 0
    private let builtins: [RegisteredCommand]
    private var extensions: [RegisteredCommand] = []
    /// Features that are off: their commands aren't registered until they are on again.
    private var disabledFeatures: Set<Feature> = []
    private var byID: [CommandID: RegisteredCommand] = [:]
    private var byKeyword: [String: CommandID] = [:]
    private var index = SearchIndex([])

    /// `builtins` are the commands of the app's `Builtin` table, in its order.
    public init(builtins: [RegisteredCommand] = []) {
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

    /// Unregisters the commands of the features in `disabled` and registers the rest again, for when
    /// settings.json turned a feature off or on.
    public func setDisabledFeatures(_ disabled: Set<Feature>) {
        guard disabled != disabledFeatures else { return }
        disabledFeatures = disabled
        rebuild()
    }

    public func command(_ id: CommandID) -> RegisteredCommand? {
        byID[id]
    }

    /// The command whose keyword `keyword` is, if typing it and a space opens its frame.
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

    private func rebuild() {
        changes += 1
        commands = []
        byID = [:]
        let enabled = (builtins + extensions).filter {
            $0.feature.map { !disabledFeatures.contains($0) } ?? true
        }
        for command in enabled where byID[command.id] == nil {
            commands.append(command)
            byID[command.id] = command
        }

        byKeyword = [:]
        keywordConflicts = []
        // A hidden command is reachable by `run` actions only (docs/extensions.md), and one that
        // takes no text has no frame to open with it.
        for command in commands where command.isOffered && command.input != .none {
            guard let keyword = command.keyword?.lowercased() else { continue }
            if let winner = byKeyword[keyword] {
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
                (item(for: command), [command.keyword].compactMap { $0 } + command.search)
            })
    }

    /// A command's root row. Its accessory is its keyword when it has one in effect, so the row
    /// teaches it.
    private func item(for command: RegisteredCommand) -> Item {
        let keyword = command.keyword.flatMap { byKeyword[$0.lowercased()] == command.id ? $0 : nil }
        return Item(
            id: Self.itemID(for: command.id), title: command.title, subtitle: command.subtitle,
            icon: command.icon, accessory: keyword ?? "Command", actions: [.run(command: command.id)])
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
