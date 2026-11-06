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
    public var ai = AI()
    /// Why a field the file sets was ignored for its default. A cosmetic value that is wrong or out
    /// of range shouldn't cost the whole file, so it is reported here instead of making it invalid.
    public private(set) var ignored: [String] = []

    public init() {}

    /// The `ai` object. Preferences only: nothing here grants anything.
    public struct AI: Equatable, Sendable {
        /// Which agent answers Ask AI; nil (the default) means the first one that's ready, in
        /// `AgentProvider.allCases` order (Codex first).
        public var provider: AgentProvider?

        public init(provider: AgentProvider? = nil) {
            self.provider = provider
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
        case hotkey, paletteWidth, ai
    }

    private enum AIKeys: String, CodingKey {
        case provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? .default
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
        if container.contains(.ai), (try? container.decodeNil(forKey: .ai)) != true {
            decodeAI(try? container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai))
        }
    }

    /// Like the width, a wrong provider is ignored on its own: Ask AI then uses the first ready one.
    private mutating func decodeAI(_ ai: KeyedDecodingContainer<AIKeys>?) {
        guard let ai else {
            ignored.append("ai must be an object; using defaults")
            return
        }
        // Null, like a missing field, means automatic.
        guard ai.contains(.provider), (try? ai.decodeNil(forKey: .provider)) == false else { return }
        if let provider = try? ai.decode(AgentProvider.self, forKey: .provider) {
            self.ai.provider = provider
        } else {
            let names = AgentProvider.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
            ignored.append("ai.provider must be \(names); using the first one that's ready")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(paletteWidth, forKey: .paletteWidth)
        // Only when chosen, so a new file stays minimal; `update` removes it again for automatic.
        if let provider = ai.provider {
            var nested = container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai)
            try nested.encode(provider, forKey: .provider)
        }
    }
}
