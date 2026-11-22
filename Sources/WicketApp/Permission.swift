import ApplicationServices
import EventKit
import Foundation

/// A macOS permission an extension declares in its manifest (`permissions`). macOS grants it to Wicket,
/// the responsible process of every program Wicket starts, so one grant serves every enabled extension and
/// whatever the agent runs: a declaration tells the user and lets Wicket ask first, and confines nothing.
enum Permission: String, Codable, Sendable, CaseIterable {
  case accessibility, calendar

  /// Where it stands for Wicket.
  enum Status: Sendable { case granted, askable, denied }

  /// Its pane in System Settings, Privacy & Security.
  var pane: URL {
    let name = self == .accessibility ? "Accessibility" : "Calendars"
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + name)!
  }
  var title: String { self == .accessibility ? "Accessibility" : "Calendar" }
}

/// The system's permission state, behind closures so tests never touch TCC. Reading a status never
/// prompts; only `request` may, and only Calendar can be asked for inline: Accessibility is granted in
/// System Settings alone.
struct Permissions: Sendable {
  var status: @MainActor @Sendable (Permission) -> Permission.Status
  /// Asks macOS from Wicket's own process, so the prompt names Wicket; returns once the user answered.
  var request: @MainActor @Sendable (Permission) async -> Void

  static let system = Permissions(
    status: { permission in
      switch permission {
      case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
      case .calendar:
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .askable
        default: return .denied
        }
      }
    },
    request: { permission in
      guard permission == .calendar else { return }
      _ = try? await EKEventStore().requestFullAccessToEvents()
    })

  /// What `command` declares and Wicket does not hold now.
  @MainActor func missing(_ command: ExtensionCommand) -> [Permission] {
    command.manifest.permissions.filter { status($0) != .granted }
  }

  /// Wicket's own rows in place of the program's view while a declared permission is missing: one per
  /// permission, which asks for it where macOS lets Wicket ask, else opens its pane. `rerun` is the
  /// request the program did not get, which a Calendar grant follows. Nil when nothing is missing.
  @MainActor func gate(_ command: ExtensionCommand, rerun: Address) -> ProviderView? {
    let missing = missing(command)
    guard !missing.isEmpty else { return nil }
    return ProviderView(
      items: missing.map { permission in
        let open = RowAction.open(permission.pane, title: "Open Privacy & Security")
        let row = { (subtitle: String, action: RowAction) in
          Row(
            id: "permission:" + permission.rawValue, title: "Allow \(permission.title) for Wicket",
            subtitle: subtitle, icon: permission == .accessibility ? "lock" : "calendar", actions: [action])
        }
        switch (permission, status(permission)) {
        case (.accessibility, _):
          // A grant made for an older copy of Wicket (an update, a rebuild) still shows its switch on but
          // no longer applies.
          return row(
            "\(command.manifest.name) needs it. Already on? Remove Wicket there and add it again", open)
        case (.calendar, .askable):
          return row(
            "\(command.manifest.name) needs it",
            RowAction(.grant(.calendar, then: rerun), title: "Allow Calendar Access"))
        case (.calendar, _):
          return row("\(command.manifest.name) needs it. Turn on Wicket under Calendars", open)
        }
      })
  }
}
