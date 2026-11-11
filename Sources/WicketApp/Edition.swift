import Foundation

/// Which Wicket this is: the released app, or Wicket Dev, a local build that runs beside it with its
/// own settings folder, hotkey and no updates. Read once from the app bundle's identifier
/// (`app.wicket.Wicket` or `app.wicket.Wicket.dev`). Outside a bundle (`swift run`, tests) it is
/// `.release`, so folders and defaults stay the documented ones.
enum Edition: Equatable {
  case release, dev

  static let current = Edition(bundleIdentifier: Bundle.main.bundleIdentifier)

  /// `.dev` for an identifier ending in `.dev`, else `.release`.
  init(bundleIdentifier: String?) {
    self = bundleIdentifier?.hasSuffix(".dev") == true ? .dev : .release
  }

  /// The name the user sees.
  var name: String { self == .dev ? "Wicket Dev" : "Wicket" }

  /// The default launcher shortcut: ⌥Space, or ⌃⌥Space so Wicket Dev never takes the released app's.
  var defaultHotkey: Shortcut {
    Shortcut(key: "space", modifiers: self == .dev ? [.control, .option] : .option)
  }

  /// Only the released app updates itself; a local build must never update into the release.
  var updates: Bool { self == .release }

  /// `~/.config/wicket`, or `~/.config/wicket-dev`.
  var configFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: self == .dev ? ".config/wicket-dev" : ".config/wicket", directoryHint: .isDirectory)
  }

  /// The one place the working folder is chosen, for the app and the headless mode:
  /// `WICKET_CONFIG_DIR` if set, else the edition's folder.
  func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let path = environment["WICKET_CONFIG_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return configFolder
  }

  /// Where private state the agent must not read lives: `~/Library/Application Support/app.wicket.Wicket`
  /// (`.dev` for Wicket Dev), a folder name 0.0.x never used. With `WICKET_CONFIG_DIR` set it is a sibling
  /// of that folder, `<folder>-private`, so a test copy never touches the real one.
  func privateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let path = environment["WICKET_CONFIG_DIR"], !path.isEmpty {
      let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      return folder.deletingLastPathComponent().appending(
        path: folder.lastPathComponent + "-private", directoryHint: .isDirectory)
    }
    return URL.applicationSupportDirectory.appending(
      path: self == .dev ? "app.wicket.Wicket.dev" : "app.wicket.Wicket", directoryHint: .isDirectory)
  }
}
