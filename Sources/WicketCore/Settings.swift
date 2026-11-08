import Foundation

/// The steps of `Settings.textSize`, how large a page's text is. Small is the original look; each
/// step is two points more body text.
public enum TextSize: String, CaseIterable, Sendable, Codable {
    case small, medium, large, larger

    /// The body text in points; headings, code and labels keep their proportion to it.
    public var bodySize: Double {
        switch self {
        case .small: 13
        case .medium: 15
        case .large: 17
        case .larger: 19
        }
    }
}

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
    /// How large a page's text is: a detail, Run Agent's answer.
    public var textSize = TextSize.medium
    /// Whether a page fetches what it shows from the network (remote images). On by default; when
    /// off, a page offers Load Images for itself. A preference, not a permission: Wicket fetches,
    /// never the page's author.
    public var showOnlineContent = true
    public var ai = AI()
    /// Why a field the file sets was ignored for its default. A cosmetic value that is wrong or out
    /// of range shouldn't cost the whole file, so it is reported here instead of making it invalid.
    public private(set) var ignored: [String] = []

    public init() {}

    /// The `ai` object. Preferences only: what an agent may do is its own configuration.
    public struct AI: Equatable, Sendable {
        /// Whether Wicket uses AI at all (`ai.enabled`, Settings ▸ AI). Off, Run Agent and Follow Up
        /// aren't registered, so nothing in Wicket asks a model.
        public var enabled = true
        /// Which agent answers Run Agent; nil (none chosen yet) means the first one that's ready, in
        /// `AgentProvider.allCases` order (Claude first).
        public var provider: AgentProvider?
        /// How Claude Code runs (`ai.claude`).
        public var claude = AgentProvider.claude.defaultOptions
        /// How Codex runs (`ai.codex`).
        public var codex = AgentProvider.codex.defaultOptions

        public init(provider: AgentProvider? = nil) {
            self.provider = provider
        }

        public subscript(provider: AgentProvider) -> AgentOptions {
            get {
                switch provider {
                case .claude: claude
                case .codex: codex
                }
            }
            set {
                switch provider {
                case .claude: claude = newValue
                case .codex: codex = newValue
                }
            }
        }
    }

    /// A settings file that exists but can't be read as settings: not JSON, or a known field with an
    /// invalid value.
    public struct InvalidFile: LocalizedError, Equatable, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { "settings.json is invalid: \(description)" }
    }

    /// `$WICKET_CONFIG_DIR`, else `~/.config/wicket` (`~/.config/wicket-dev` for Wicket Dev).
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["WICKET_CONFIG_DIR"], !dir.isEmpty {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: Edition.current.configFolder)
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
            object = merge(file, old: try old.fields(), new: try new.fields()) as? [String: Any] ?? [:]
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

    /// The file's bytes, or nil if it does not exist.
    private static func contents(of url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private static func decode(_ data: Data) throws -> Settings {
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

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkey, paletteWidth, showInMenuBar, textSize, showOnlineContent, ai
    }

    private enum AIKeys: String, CodingKey {
        case enabled, provider, codex, claude
    }

    private enum AgentKeys: String, CodingKey {
        case model, effort, speed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.hotkey), (try? container.decodeNil(forKey: .hotkey)) == false {
            decodeHotkey(container)
        }
        let range = Self.paletteWidths
        paletteWidth =
            field(
                container, .paletteWidth, valid: range.contains, nullWarns: true,
                "paletteWidth must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)); "
                    + "using \(Int(paletteWidth))") ?? paletteWidth
        showInMenuBar =
            field(container, .showInMenuBar, "showInMenuBar must be true or false; showing the menu bar icon")
            ?? showInMenuBar
        showOnlineContent =
            field(
                container, .showOnlineContent,
                "showOnlineContent must be true or false; showing online content")
            ?? showOnlineContent
        textSize =
            field(container, .textSize, "textSize must be small, medium, large or larger; using medium")
            ?? textSize
        if container.contains(.ai), (try? container.decodeNil(forKey: .ai)) != true {
            decodeAI(try? container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai))
        }
    }

    /// Like the width, a bad hotkey costs only itself: it is ignored with its reason and the palette
    /// keeps the default, so Wicket can still be summoned. It must leave typing alone
    /// (`Shortcut.leavesTypingAlone`).
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

    /// The valid value the file gives `key`, else nil for the default. Absent or null (unless
    /// `nullWarns`) is the default silently; anything else that doesn't decode or isn't `valid` is
    /// ignored on its own with `warning`, so a wrong cosmetic value never costs the whole file.
    private mutating func field<Key: CodingKey, Value: Decodable>(
        _ object: KeyedDecodingContainer<Key>, _ key: Key, valid: (Value) -> Bool = { _ in true },
        nullWarns: Bool = false, _ warning: String
    ) -> Value? {
        guard object.contains(key), nullWarns || (try? object.decodeNil(forKey: key)) != true else {
            return nil
        }
        if let value = try? object.decode(Value.self, forKey: key), valid(value) { return value }
        ignored.append(warning)
        return nil
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
        self.ai.enabled =
            field(ai, .enabled, "ai.enabled must be true or false; AI stays on") ?? self.ai.enabled
        // Null, like a missing field, means none chosen.
        let names = AgentProvider.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
        self.ai.provider =
            field(ai, .provider, "ai.provider must be \(names); using the first one that's ready")
            ?? self.ai.provider
        for (key, provider) in [(AIKeys.claude, AgentProvider.claude), (.codex, .codex)]
        where ai.contains(key) && (try? ai.decodeNil(forKey: key)) != true {
            decodeAgent(
                try? ai.nestedContainer(keyedBy: AgentKeys.self, forKey: key), provider, key.stringValue)
        }
    }

    /// One agent's options; each field fails alone and leaves the provider's default.
    private mutating func decodeAgent(
        _ object: KeyedDecodingContainer<AgentKeys>?, _ provider: AgentProvider, _ key: String
    ) {
        guard let object else {
            ignored.append("ai.\(key) must be an object; using the defaults")
            return
        }
        let valid = AgentOptions.isValidValue
        ai[provider].model =
            field(object, .model, valid: valid, "ai.\(key).model must be one word; using the default")
            ?? ai[provider].model
        ai[provider].effort =
            field(object, .effort, valid: valid, "ai.\(key).effort must be one word; using the default")
            ?? ai[provider].effort
        ai[provider].speed =
            field(object, .speed, "ai.\(key).speed must be \"regular\" or \"fast\"; using regular")
            ?? ai[provider].speed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(paletteWidth, forKey: .paletteWidth)
        // Only when hidden, so a new file stays minimal and `update` removes it when shown again.
        if !showInMenuBar { try container.encode(false, forKey: .showInMenuBar) }
        if textSize != .medium { try container.encode(textSize, forKey: .textSize) }
        if !showOnlineContent { try container.encode(false, forKey: .showOnlineContent) }
        // Only what is chosen, so a new file stays minimal; `update` removes a field set back to the
        // provider's default (and the object once nothing is left in it).
        if ai != AI() {
            var nested = container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai)
            if !ai.enabled { try nested.encode(false, forKey: .enabled) }
            try nested.encodeIfPresent(ai.provider, forKey: .provider)
            for (key, provider) in [(AIKeys.claude, AgentProvider.claude), (.codex, .codex)] {
                let options = ai[provider]
                let defaults = provider.defaultOptions
                guard options != defaults else { continue }
                var fields = nested.nestedContainer(keyedBy: AgentKeys.self, forKey: key)
                if options.model != defaults.model { try fields.encode(options.model, forKey: .model) }
                if options.effort != defaults.effort { try fields.encode(options.effort, forKey: .effort) }
                if options.speed != defaults.speed { try fields.encode(options.speed, forKey: .speed) }
            }
        }
    }
}
