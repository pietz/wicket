import AppKit
import Observation
import Sparkle

/// In-app updates for the released app through Sparkle: it checks the appcast (`SUFeedURL` in
/// Info.plist) every six hours by default and offers a signed, notarized update.
@MainActor @Observable
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
  private(set) var availableUpdate: String?
  @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

  /// Starts Sparkle; nil for Wicket Dev and for anything outside an app bundle with a feed
  /// (`swift run`, tests), where Sparkle would only show errors.
  init?(edition: Edition = .current, bundle: Bundle = .main) {
    guard edition.updates, bundle.bundleIdentifier != nil,
      bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
    else { return nil }
    super.init()
    _ = controller
  }

  /// Brings forward the scheduled update, or checks now and shows the result.
  func checkForUpdates() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }

  var supportsGentleScheduledUpdateReminders: Bool { true }
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool { false }

  func standardUserDriverWillHandleShowingUpdate(
    _ handled: Bool, forUpdate item: SUAppcastItem, state: SPUUserUpdateState
  ) {
    if !handled { availableUpdate = item.displayVersionString }
  }
  func standardUserDriverDidReceiveUserAttention(forUpdate item: SUAppcastItem) { availableUpdate = nil }
  func standardUserDriverWillFinishUpdateSession() { availableUpdate = nil }

  /// Whether Sparkle checks on its own. Kept in Sparkle's user defaults, not config.json: it is the
  /// app's housekeeping, on by default (`SUEnableAutomaticChecks`).
  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
}
