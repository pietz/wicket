import Foundation

/// The steps of `Settings.textSize`, how large a page's text is. Small is the original look; each
/// step is two points more body text.
public enum TextSize: String, CaseIterable, Sendable {
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
    public var ai = AI()
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
        /// Which agent answers Run Agent; nil (none chosen yet) means the first one that's ready, in
        /// `AgentProvider.allCases` order (Claude first).
        public var provider: AgentProvider?
        /// How Claude Code runs (`ai.claude`).
        public var claude = AgentProvider.claude.defaultOptions
        /// How Codex runs (`ai.codex`).
        public var codex = AgentProvider.codex.defaultOptions
        /// Whether an answer is drawn as its text arrives (`ai.streamAnswers`). Off by default: the
        /// page shows the agent working, each message once it is whole, then the answer at once.
        public var streamAnswers = false

        public init(provider: AgentProvider? = nil, streamAnswers: Bool = false) {
            self.provider = provider
            self.streamAnswers = streamAnswers
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
    /// file keeps working after a rename (Ask AI's feature became Run Agent's, 2026-11-08; Web Search became
    /// Links when Search the Web was removed, 2026-11-08). The file is rewritten
    /// with the new name the next time Settings changes something.
    static let renamed: [(object: String, old: String, new: String)] = [
        ("features", "ask-ai", "ai"),
        ("features", "web-search", "links"),
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

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkey, paletteWidth, showInMenuBar, textSize, ai, features
    }

    private enum AIKeys: String, CodingKey {
        case provider, codex, claude, streamAnswers
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
        if container.contains(.textSize), (try? container.decodeNil(forKey: .textSize)) != true {
            if let size = (try? container.decode(String.self, forKey: .textSize)).flatMap(TextSize.init) {
                textSize = size
            } else {
                ignored.append("textSize must be small, medium, large or larger; using medium")
            }
        }
        if container.contains(.ai), (try? container.decodeNil(forKey: .ai)) != true {
            decodeAI(try? container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai))
        }
        if container.contains(.features), (try? container.decodeNil(forKey: .features)) != true {
            decodeFeatures(try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .features))
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

    /// Each entry stands alone: an unknown feature or a value that isn't a
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
    /// "apple", a provider older builds offered, quietly means none chosen, so the first ready one
    /// (Claude, else ChatGPT) takes over.
    private mutating func decodeAI(_ ai: KeyedDecodingContainer<AIKeys>?) {
        guard let ai else {
            ignored.append("ai must be an object; using defaults")
            return
        }
        // Null, like a missing field, means none chosen.
        if ai.contains(.provider), (try? ai.decodeNil(forKey: .provider)) == false,
            (try? ai.decode(String.self, forKey: .provider)) != "apple"
        {
            if let provider = try? ai.decode(AgentProvider.self, forKey: .provider) {
                self.ai.provider = provider
            } else {
                let names = AgentProvider.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                ignored.append("ai.provider must be \(names); using the first one that's ready")
            }
        }
        if ai.contains(.streamAnswers), (try? ai.decodeNil(forKey: .streamAnswers)) != true {
            if let stream = try? ai.decode(Bool.self, forKey: .streamAnswers) {
                self.ai.streamAnswers = stream
            } else {
                ignored.append("ai.streamAnswers must be true or false; not streaming answers")
            }
        }
        for (key, provider) in [(AIKeys.claude, AgentProvider.claude), (.codex, .codex)]
        where ai.contains(key) && (try? ai.decodeNil(forKey: key)) != true {
            decodeAgent(
                try? ai.nestedContainer(keyedBy: AgentKeys.self, forKey: key), provider, key.stringValue)
        }
    }

    /// One agent's options; each field fails alone and leaves the provider's default. A model of
    /// "default", which older builds wrote for the agent's own, is the provider's default too. A
    /// `permission` here is ignored with its reason: the file never grants consent.
    private mutating func decodeAgent(
        _ object: KeyedDecodingContainer<AgentKeys>?, _ provider: AgentProvider, _ key: String
    ) {
        guard let object else {
            ignored.append("ai.\(key) must be an object; using the defaults")
            return
        }
        for field in [AgentKeys.model, .effort] where object.contains(field) {
            if (try? object.decodeNil(forKey: field)) == true { continue }
            guard let value = try? object.decode(String.self, forKey: field), AgentOptions.isValidValue(value)
            else {
                ignored.append(
                    "ai.\(key).\(field.stringValue) must be one word; using the default")
                continue
            }
            if field == .model {
                if value != "default" { ai[provider].model = value }
            } else {
                ai[provider].effort = value
            }
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(paletteWidth, forKey: .paletteWidth)
        // Only when hidden, so a new file stays minimal and `update` removes it when shown again.
        if !showInMenuBar { try container.encode(false, forKey: .showInMenuBar) }
        if textSize != .medium { try container.encode(textSize.rawValue, forKey: .textSize) }
        // Only what is chosen, so a new file stays minimal; `update` removes a field set back to the
        // provider's default (and the object once nothing is left in it).
        if ai != AI() {
            var nested = container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai)
            try nested.encodeIfPresent(ai.provider, forKey: .provider)
            if ai.streamAnswers { try nested.encode(true, forKey: .streamAnswers) }
            for (key, provider) in [(AIKeys.claude, AgentProvider.claude), (.codex, .codex)] {
                let options = ai[provider]
                let defaults = provider.defaultOptions
                guard options != defaults else { continue }
                var fields = nested.nestedContainer(keyedBy: AgentKeys.self, forKey: key)
                if options.model != defaults.model { try fields.encode(options.model, forKey: .model) }
                if options.effort != defaults.effort { try fields.encode(options.effort, forKey: .effort) }
                if options.speed != defaults.speed {
                    try fields.encode(options.speed.rawValue, forKey: .speed)
                }
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
