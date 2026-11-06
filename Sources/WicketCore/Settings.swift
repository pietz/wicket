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
    /// Why a field the file sets was ignored for its default. A cosmetic value that is wrong or out
    /// of range shouldn't cost the whole file, so it is reported here instead of making it invalid.
    public private(set) var ignored: [String] = []

    public init() {}

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
    /// keeping every other field, including ones this build doesn't know. A missing file is created
    /// with all current values. An invalid file is never overwritten: this throws `InvalidFile`.
    /// The file is written pretty-printed with sorted keys, atomically, and only if something changed.
    public static func update(at url: URL, _ change: (inout Settings) -> Void) throws {
        let url = url.resolvingSymlinksInPath()
        let data = try contents(of: url)
        let old = try data.map(decode) ?? Settings()
        var new = old
        change(&new)
        var object: [String: Any] = [:]
        if let data {  // `decode` accepted it, so it holds a JSON object.
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        let oldFields = try old.fields()
        var changed = data == nil
        for (key, value) in try new.fields() where data == nil || oldFields[key] != value {
            object[key] = value
            changed = true
        }
        guard changed else { return }
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
    private func fields() throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: data) as? [String: NSObject] ?? [:]
    }
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hotkey, paletteWidth
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
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(paletteWidth, forKey: .paletteWidth)
    }
}
