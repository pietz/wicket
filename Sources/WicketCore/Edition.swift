import Foundation

/// Which Wicket this is: the released app, or Wicket Dev, a local build that runs beside it with its
/// own settings, data, hotkey and no updates. Read once from the app bundle's identifier, so the
/// bundled `wicket` tool (Contents/Helpers) follows the app it ships in.
public enum Edition: Sendable, Equatable {
    case release, dev

    /// The edition of the app bundle this process runs from. Outside a bundle (`swift run`, tests)
    /// it is `.release`, so paths and defaults stay the documented ones.
    public static let current = Edition(bundleIdentifier: enclosingAppIdentifier())

    /// `.dev` for an identifier ending in `.dev` (`app.wicket.Wicket.dev`), else `.release`.
    public init(bundleIdentifier: String?) {
        self = bundleIdentifier?.hasSuffix(".dev") == true ? .dev : .release
    }

    /// The app's name: the folder name under Application Support, and the name the user sees.
    public var name: String {
        switch self {
        case .release: "Wicket"
        case .dev: "Wicket Dev"
        }
    }

    /// `~/.config/wicket`, or `~/.config/wicket-dev`.
    public var configFolder: String {
        switch self {
        case .release: ".config/wicket"
        case .dev: ".config/wicket-dev"
        }
    }

    /// The palette's default hotkey: ⌥Space, or ⌃⌥Space so Wicket Dev never takes the released
    /// app's.
    public var defaultHotkey: Shortcut {
        switch self {
        case .release: Shortcut(key: "space", modifiers: .option)
        case .dev: Shortcut(key: "space", modifiers: [.control, .option])
        }
    }

    /// `~/Library/Application Support/Wicket` (or `Wicket Dev`).
    public var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: name, directoryHint: .isDirectory)
    }

    /// The identifier of the app this process belongs to: its own bundle's, or for the helper tool
    /// at `Wicket.app/Contents/Helpers/wicket`, the enclosing app's.
    private static func enclosingAppIdentifier() -> String? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleIdentifier }
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let app, app.pathExtension == "app" else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}
