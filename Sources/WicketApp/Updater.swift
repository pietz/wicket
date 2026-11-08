import Sparkle
import WicketCore

/// In-app updates for the released app, through Sparkle: it checks the appcast (`SUFeedURL` in
/// Info.plist) once a day by default and offers a signed, notarized update. Wicket Dev has none, so
/// a local build never updates itself into the released app.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Starts Sparkle for the released app; nil for Wicket Dev.
    init?(edition: Edition = .current) {
        guard edition == .release else { return nil }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Checks now and shows Sparkle's window with the result.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether Sparkle checks on its own. Kept in Sparkle's user defaults, not settings.json: it is
    /// the app's housekeeping, and on by default (`SUEnableAutomaticChecks`).
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
