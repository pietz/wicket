import Foundation

/// User settings from `settings.json` in the config directory, editable by people and agents.
/// Every field is optional in the file, and unknown fields are ignored, so files written for newer
/// builds still load.
public struct Settings: Equatable, Sendable {
    public static let defaultPaletteWidth: Double = 600
    public static let paletteWidths: ClosedRange<Double> = 480...900

    public var hotkey: Shortcut = .default
    /// The palette's width in points, within `paletteWidths`.
    public var paletteWidth = defaultPaletteWidth
    /// Whether Wicket shows its icon in the menu bar. A way back in, not a permission, so the file
    /// may set it.
    public var showInMenuBar = true
    public var ai = AI()
    /// The `webSearch` object: where Search the Web goes.
    public var webSearch = WebSearch()
    /// What the user bound to commands: a global hotkey, an alias. Keyed by `CommandID`, written in
    /// the file by its canonical spelling (`"builtin:run-agent"`, `"ext:github/search"`). Entries for
    /// commands that aren't registered stay here (the extension may be installed later) and do
    /// nothing until they are.
    public var commands: [CommandID: CommandBinding] = [:]
    /// The built-in features turned off. The file says `"features": {"files": false}`; a feature it
    /// doesn't mention, or sets to true, is on.
    public var disabledFeatures: Set<Feature> = []
    /// Why a field the file sets was ignored for its default. A cosmetic value that is wrong or out
    /// of range shouldn't cost the whole file, so it is reported here instead of making it invalid.
    public private(set) var ignored: [String] = []

    public init() {}

    public func isEnabled(_ feature: Feature) -> Bool {
        !disabledFeatures.contains(feature)
    }

    public mutating func setEnabled(_ feature: Feature, _ enabled: Bool) {
        if enabled { disabledFeatures.remove(feature) } else { disabledFeatures.insert(feature) }
    }

    /// The `ai` object. Preferences only: nothing here grants anything, so the agents' permission
    /// level is not here (`AgentPermission`).
    public struct AI: Equatable, Sendable {
        /// Which agent answers Run Agent; nil (the default) means the first one that's ready, in
        /// `AgentProvider.allCases` order (Codex first).
        public var provider: AgentProvider?
        /// How Codex runs (`ai.codex`).
        public var codex = AgentOptions()
        /// How Claude Code runs (`ai.claude`).
        public var claude = AgentOptions()

        public init(provider: AgentProvider? = nil) {
            self.provider = provider
        }

        /// The options of an agent CLI; Apple's model has none.
        public subscript(provider: AgentProvider) -> AgentOptions {
            get {
                switch provider {
                case .codex: codex
                case .claude: claude
                case .apple: AgentOptions()
                }
            }
            set {
                switch provider {
                case .codex: codex = newValue
                case .claude: claude = newValue
                case .apple: break
                }
            }
        }
    }

    /// The `webSearch` object.
    public struct WebSearch: Equatable, Sendable {
        /// The search address, `{query}` standing for the typed text (`WebQuery.searchURL`).
        public var url: String

        public init(url: String = WebQuery.defaultTemplate) {
            self.url = url
        }
    }

    /// A settings file that exists but can't be read as settings: not JSON, or a known field with an
    /// invalid value.
    public struct InvalidFile: LocalizedError, Equatable, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { "settings.json is invalid: \(description)" }
    }

    /// `$WICKET_CONFIG_DIR`, else `~/.config/wicket`.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["WICKET_CONFIG_DIR"], !dir.isEmpty {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/wicket")
    }

    /// Defaults if the file does not exist; throws `InvalidFile` if it exists but is not valid.
    public static func load(from url: URL) throws -> Settings {
        guard let data = try contents(of: url) else { return Settings() }
        return try decode(data)
    }

    /// Applies `change` to the settings in the file and writes back only the fields it changed,
    /// keeping every other field, including ones this build doesn't know (inside objects such as
    /// `ai` too). A field set back to its absent default is removed. A missing file is created with
    /// all current values. An invalid file is never overwritten: this throws `InvalidFile`. The file
    /// is written pretty-printed with sorted keys, atomically, and only if something changed.
    public static func update(at url: URL, _ change: (inout Settings) -> Void) throws {
        let url = url.resolvingSymlinksInPath()
        let data = try contents(of: url)
        let old = try data.map(decode) ?? Settings()
        var new = old
        change(&new)
        let object: [String: Any]
        if let data {  // `decode` accepted it, so it holds a JSON object.
            let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            object =
                merge(migrated(file), old: try old.fields(), new: try new.fields()) as? [String: Any] ?? [:]
            guard !NSDictionary(dictionary: object).isEqual(to: file) else { return }
        } else {
            object = try new.fields()
        }
        let json = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (json + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// Keys an older Wicket used, by the object holding them, and what they are called now, so a
    /// file keeps working after a rename (Ask AI became Run Agent, 2026-11-08). The file is rewritten
    /// with the new name the next time Settings changes something.
    static let renamed: [(object: String, old: String, new: String)] = [
        ("commands", "builtin:ask-ai", "builtin:run-agent"),
        ("features", "ask-ai", "ai"),
    ]

    /// `file` with every renamed key under its current name; a key already under the new name wins.
    static func migrated(_ file: [String: Any]) -> [String: Any] {
        var file = file
        for rename in renamed {
            guard var object = file[rename.object] as? [String: Any],
                let value = object.removeValue(forKey: rename.old)
            else { continue }
            if object[rename.new] == nil { object[rename.new] = value }
            file[rename.object] = object
        }
        return file
    }

    /// The file's bytes, or nil if it does not exist.
    private static func contents(of url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private static func decode(_ data: Data) throws -> Settings {
        var data = data
        if let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            case let current = migrated(file), !NSDictionary(dictionary: current).isEqual(to: file),
            let rewritten = try? JSONSerialization.data(withJSONObject: current)
        {
            data = rewritten
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch let error as DecodingError {
            throw InvalidFile(description: describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context? =
            switch error {
            case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context),
                .valueNotFound(_, let context):
                context
            @unknown default: nil
            }
        guard let context else { return String(describing: error) }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    /// The known fields as JSON values, keyed like the file.
    private func fields() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// `file` with the change from `old` to `new` applied: a changed value replaces the file's, one
    /// gone from `new` is removed, and objects are merged key by key, so whatever `old` and `new`
    /// agree on keeps the file's spelling and keys this build doesn't know stay. Nil removes the key.
    private static func merge(_ file: Any?, old: Any?, new: Any?) -> Any? {
        if let old = old as? NSObject, let new = new as? NSObject, old.isEqual(new) { return file }
        guard new is [String: Any] || (new == nil && old is [String: Any]) else { return new }
        let oldObject = old as? [String: Any] ?? [:]
        let newObject = new as? [String: Any] ?? [:]
        var object = file as? [String: Any] ?? [:]
        for key in Set(oldObject.keys).union(newObject.keys) {
            object[key] = merge(object[key], old: oldObject[key], new: newObject[key])
        }
        return new == nil && object.isEmpty ? nil : object
    }
}

/// What settings.json binds to one command. A preference, never consent (CONCEPT principle 6):
/// binding a hotkey or an alias to an extension's command doesn't enable or approve the extension.
public struct CommandBinding: Hashable, Sendable {
    /// Runs the command from anywhere, without the root search first.
    public var hotkey: Shortcut?
    /// One word typed in the root search: alone it lists the command first; followed by a space it
    /// works as the command's keyword (`CommandRegistry`). Matched ignoring case.
    public var alias: String?

    public init(hotkey: Shortcut? = nil, alias: String? = nil) {
        self.hotkey = hotkey
        self.alias = alias
    }

    public var isEmpty: Bool { hotkey == nil && alias == nil }

    /// One word: not empty, no spaces, at most 32 characters.
    public static func isValidAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.count <= 32 && !alias.contains(where: \.isWhitespace)
    }
}

extension Settings {
    /// Who already has `hotkey` if `command` took it: the palette, or the first other registered
    /// command (in canonical id order) settings.json binds it to. A binding of a command that isn't
    /// registered is inert (`CommandHotkeys`) and takes nothing, so it is no conflict. For the
    /// Shortcuts pane, which refuses to create a collision rather than leave it to `CommandHotkeys`.
    public func hotkeyConflict(
        _ hotkey: Shortcut, for command: CommandID, isRegistered: (CommandID) -> Bool
    ) -> CommandHotkeys.Rejection.Reason? {
        if hotkey == self.hotkey { return .palette }
        return bindingOwner(except: command, isRegistered: isRegistered) { $0.hotkey == hotkey }
            .map { .taken(by: $0) }
    }

    /// The first other registered command (in canonical id order) that settings.json gives `alias`,
    /// ignoring case. Like a hotkey, an alias of a command that isn't registered takes nothing.
    public func aliasConflict(
        _ alias: String, for command: CommandID, isRegistered: (CommandID) -> Bool
    ) -> CommandID? {
        let word = alias.lowercased()
        return bindingOwner(except: command, isRegistered: isRegistered) { $0.alias?.lowercased() == word }
    }

    private func bindingOwner(
        except command: CommandID, isRegistered: (CommandID) -> Bool, where matches: (CommandBinding) -> Bool
    ) -> CommandID? {
        commands.filter { $0.key != command && isRegistered($0.key) && matches($0.value) }
            .map(\.key).min { $0.description < $1.description }
    }
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkey, paletteWidth, showInMenuBar, ai, webSearch, commands, features
    }

    private enum WebSearchKeys: String, CodingKey {
        case url
    }

    private enum CommandKeys: String, CodingKey {
        case hotkey, alias
    }

    private enum AIKeys: String, CodingKey {
        case provider, codex, claude
    }

    private enum AgentKeys: String, CodingKey {
        case model, effort, speed
        /// Never read: a permission is set only in Wicket's UI (principle 6).
        case permission
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.hotkey), (try? container.decodeNil(forKey: .hotkey)) == false {
            decodeHotkey(container)
        }
        if container.contains(.paletteWidth) {
            let width = try? container.decode(Double.self, forKey: .paletteWidth)
            if let width, Self.paletteWidths.contains(width) {
                paletteWidth = width
            } else {
                let range = Self.paletteWidths
                ignored.append(
                    "paletteWidth must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)); "
                        + "using \(Int(paletteWidth))")
            }
        }
        if container.contains(.showInMenuBar), (try? container.decodeNil(forKey: .showInMenuBar)) != true {
            if let show = try? container.decode(Bool.self, forKey: .showInMenuBar) {
                showInMenuBar = show
            } else {
                ignored.append("showInMenuBar must be true or false; showing the menu bar icon")
            }
        }
        if container.contains(.ai), (try? container.decodeNil(forKey: .ai)) != true {
            decodeAI(try? container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai))
        }
        if container.contains(.webSearch), (try? container.decodeNil(forKey: .webSearch)) != true {
            decodeWebSearch(try? container.nestedContainer(keyedBy: WebSearchKeys.self, forKey: .webSearch))
        }
        if container.contains(.commands), (try? container.decodeNil(forKey: .commands)) != true {
            decodeCommands(try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .commands))
        }
        if container.contains(.features), (try? container.decodeNil(forKey: .features)) != true {
            decodeFeatures(try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .features))
        }
    }

    /// Like the width, a bad hotkey costs only itself: it is ignored with its reason and the palette
    /// keeps the default, so Wicket can still be summoned. It must leave typing alone, like a
    /// command's (`Shortcut.leavesTypingAlone`).
    private mutating func decodeHotkey(_ container: KeyedDecodingContainer<CodingKeys>) {
        do {
            let hotkey = try container.decode(Shortcut.self, forKey: .hotkey)
            if hotkey.leavesTypingAlone {
                self.hotkey = hotkey
            } else {
                ignored.append("hotkey needs cmd, ctrl or option (or an F-key); using \(Shortcut.default)")
            }
        } catch {
            ignored.append("hotkey: \(Self.reason(error)); using \(Shortcut.default)")
        }
    }

    /// Each entry stands alone, like the bindings: an unknown feature or a value that isn't a
    /// boolean is ignored with its reason, and that feature stays on.
    private mutating func decodeFeatures(_ object: KeyedDecodingContainer<AnyKey>?) {
        guard let object else {
            ignored.append("features must be an object; every feature is on")
            return
        }
        for key in object.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            guard let feature = Feature(rawValue: key.stringValue) else {
                let names = Feature.allCases.map(\.rawValue).joined(separator: ", ")
                ignored.append("features: \"\(key.stringValue)\" is not a feature (\(names)); ignoring it")
                continue
            }
            if (try? object.decodeNil(forKey: key)) == true { continue }
            guard let enabled = try? object.decode(Bool.self, forKey: key) else {
                ignored.append("features.\(feature.rawValue) must be true or false; leaving it on")
                continue
            }
            setEnabled(feature, enabled)
        }
    }

    /// Each binding stands alone: a bad key, hotkey or alias is ignored with its reason and costs
    /// nothing else, like the width.
    private mutating func decodeCommands(_ object: KeyedDecodingContainer<AnyKey>?) {
        guard let object else {
            ignored.append("commands must be an object; no command has a hotkey or alias")
            return
        }
        for key in object.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            guard let id = CommandID(key.stringValue) else {
                ignored.append(
                    "commands: \"\(key.stringValue)\" is not a command id (builtin:<name> or "
                        + "ext:<extension>/<command>); ignoring it")
                continue
            }
            if (try? object.decodeNil(forKey: key)) == true { continue }
            guard let fields = try? object.nestedContainer(keyedBy: CommandKeys.self, forKey: key) else {
                ignored.append("commands.\(id) must be an object; ignoring it")
                continue
            }
            var binding = CommandBinding()
            if fields.contains(.hotkey), (try? fields.decodeNil(forKey: .hotkey)) == false {
                do {
                    let hotkey = try fields.decode(Shortcut.self, forKey: .hotkey)
                    if hotkey.leavesTypingAlone {
                        binding.hotkey = hotkey
                    } else {
                        ignored.append(
                            "commands.\(id).hotkey needs cmd, ctrl or option (or an F-key); ignoring it")
                    }
                } catch {
                    ignored.append("commands.\(id).hotkey: \(Self.reason(error)); ignoring it")
                }
            }
            if fields.contains(.alias), (try? fields.decodeNil(forKey: .alias)) == false {
                if let alias = try? fields.decode(String.self, forKey: .alias),
                    CommandBinding.isValidAlias(alias)
                {
                    binding.alias = alias
                } else {
                    ignored.append(
                        "commands.\(id).alias must be one word of at most 32 characters; ignoring it")
                }
            }
            if !binding.isEmpty { commands[id] = binding }
        }
    }

    /// A decoding error's message without its coding path.
    private static func reason(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context),
            .keyNotFound(_, let context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    /// Like the width, a wrong provider is ignored on its own: Run Agent then uses the first ready one.
    private mutating func decodeAI(_ ai: KeyedDecodingContainer<AIKeys>?) {
        guard let ai else {
            ignored.append("ai must be an object; using defaults")
            return
        }
        // Null, like a missing field, means automatic.
        if ai.contains(.provider), (try? ai.decodeNil(forKey: .provider)) == false {
            if let provider = try? ai.decode(AgentProvider.self, forKey: .provider) {
                self.ai.provider = provider
            } else {
                let names = AgentProvider.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                ignored.append("ai.provider must be \(names); using the first one that's ready")
            }
        }
        for (key, provider) in [(AIKeys.codex, AgentProvider.codex), (.claude, .claude)]
        where ai.contains(key) && (try? ai.decodeNil(forKey: key)) != true {
            decodeAgent(
                try? ai.nestedContainer(keyedBy: AgentKeys.self, forKey: key), provider, key.stringValue)
        }
    }

    /// One agent's options; each field fails alone and leaves the agent's own default. A
    /// `permission` here is ignored with its reason: the file never grants consent.
    private mutating func decodeAgent(
        _ object: KeyedDecodingContainer<AgentKeys>?, _ provider: AgentProvider, _ key: String
    ) {
        guard let object else {
            ignored.append("ai.\(key) must be an object; using \(provider.name)'s own settings")
            return
        }
        for field in [AgentKeys.model, .effort] where object.contains(field) {
            if (try? object.decodeNil(forKey: field)) == true { continue }
            guard let value = try? object.decode(String.self, forKey: field), AgentOptions.isValidValue(value)
            else {
                ignored.append(
                    "ai.\(key).\(field.stringValue) must be one word; using \(provider.name)'s default")
                continue
            }
            if field == .model { ai[provider].model = value } else { ai[provider].effort = value }
        }
        if object.contains(.speed), (try? object.decodeNil(forKey: .speed)) == false {
            if let name = try? object.decode(String.self, forKey: .speed),
                let speed = AgentSpeed(rawValue: name)
            {
                ai[provider].speed = speed
            } else {
                ignored.append("ai.\(key).speed must be \"regular\" or \"fast\"; using regular")
            }
        }
        if object.contains(.permission) {
            ignored.append(
                "ai.\(key).permission can only be set in Settings ▸ AI, since it decides what the agent may "
                    + "do without asking; ignoring it")
        }
    }

    /// Like the width, a bad search address costs only itself: Search the Web uses Google.
    private mutating func decodeWebSearch(_ object: KeyedDecodingContainer<WebSearchKeys>?) {
        guard let object else {
            ignored.append("webSearch must be an object; searching with Google")
            return
        }
        guard object.contains(.url), (try? object.decodeNil(forKey: .url)) == false else { return }
        if let url = try? object.decode(String.self, forKey: .url),
            WebQuery.searchURL(template: url, query: "test") != nil
        {
            webSearch.url = url
        } else {
            ignored.append(
                "webSearch.url must be an http or https address with {query} in its path or query; "
                    + "searching with Google")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(paletteWidth, forKey: .paletteWidth)
        // Only when hidden, so a new file stays minimal and `update` removes it when shown again.
        if !showInMenuBar { try container.encode(false, forKey: .showInMenuBar) }
        // Only what is chosen, so a new file stays minimal; `update` removes a field set back to the
        // agent's default (and the object once nothing is left in it).
        if ai != AI() {
            var nested = container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai)
            try nested.encodeIfPresent(ai.provider, forKey: .provider)
            for (key, options) in [(AIKeys.codex, ai.codex), (.claude, ai.claude)]
            where options != AgentOptions() {
                var fields = nested.nestedContainer(keyedBy: AgentKeys.self, forKey: key)
                try fields.encodeIfPresent(options.model, forKey: .model)
                try fields.encodeIfPresent(options.effort, forKey: .effort)
                if options.speed != .regular { try fields.encode(options.speed.rawValue, forKey: .speed) }
            }
        }
        // Only when changed, like the provider.
        if webSearch != WebSearch() {
            var nested = container.nestedContainer(keyedBy: WebSearchKeys.self, forKey: .webSearch)
            try nested.encode(webSearch.url, forKey: .url)
        }
        // Like the provider, only what is bound, so `update` removes a cleared binding (and the
        // object once nothing is left in it).
        let bound = commands.filter { !$0.value.isEmpty }
        if !bound.isEmpty {
            var object = container.nestedContainer(keyedBy: AnyKey.self, forKey: .commands)
            for (id, binding) in bound {
                var fields = object.nestedContainer(keyedBy: CommandKeys.self, forKey: AnyKey(id.description))
                try fields.encodeIfPresent(binding.hotkey, forKey: .hotkey)
                try fields.encodeIfPresent(binding.alias, forKey: .alias)
            }
        }
        // Only the features turned off, so `update` removes one turned back on.
        if !disabledFeatures.isEmpty {
            var object = container.nestedContainer(keyedBy: AnyKey.self, forKey: .features)
            for feature in disabledFeatures {
                try object.encode(false, forKey: AnyKey(feature.rawValue))
            }
        }
    }
}
