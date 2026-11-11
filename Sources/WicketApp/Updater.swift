import Sparkle

/// In-app updates for the released app through Sparkle: it checks the appcast (`SUFeedURL` in
/// Info.plist) once a day by default and offers a signed, notarized update.
@MainActor
final class Updater {
  private let controller: SPUStandardUpdaterController

  /// Starts Sparkle; nil for Wicket Dev and for anything outside an app bundle with a feed
  /// (`swift run`, tests), where Sparkle would only show errors.
  init?(edition: Edition = .current, bundle: Bundle = .main) {
    guard edition.updates, bundle.bundleIdentifier != nil,
      bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
    else { return nil }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  /// Checks now and shows Sparkle's window with the result.
  func checkForUpdates() { controller.checkForUpdates(nil) }

  /// Whether Sparkle checks on its own. Kept in Sparkle's user defaults, not config.json: it is the
  /// app's housekeeping, on by default (`SUEnableAutomaticChecks`).
  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
}
