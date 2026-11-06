import Foundation

/// User settings from `settings.json` in the config directory, editable by people and agents.
/// Every field is optional in the file, and unknown fields are ignored, so files written for newer
/// builds still load.
public struct Settings: Equatable, Sendable {
    public var hotkey: Shortcut = .default

    public init() {}

    /// `$WICKET_CONFIG_DIR`, else `~/.config/wicket`.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["WICKET_CONFIG_DIR"], !dir.isEmpty {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/wicket")
    }

    /// Defaults if the file does not exist; throws if it exists but is not valid.
    public static func load(from url: URL) throws -> Settings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Settings()
        }
        return try JSONDecoder().decode(Settings.self, from: data)
    }
}

extension Settings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hotkey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? .default
    }
}
