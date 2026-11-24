import AVFoundation
import ApplicationServices
import EventKit
import Foundation

/// A macOS permission an extension declares in its manifest (`permissions`). macOS grants it to Wicket,
/// the responsible process of every program Wicket starts, so one grant serves every enabled extension and
/// whatever the agent runs: a declaration tells the user and lets Wicket ask first, and confines nothing.
enum Permission: String, Codable, Sendable, CaseIterable {
  case accessibility, calendar

  /// Where it stands for Wicket.
  enum Status: String, Codable, Sendable { case granted, askable, denied }

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
  var status: @Sendable (Permission) -> Permission.Status
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

  var microphone: @Sendable () -> Permission.Status = {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: .granted
    case .undetermined: .askable
    default: .denied
    }
  }

  func snapshot() -> [String: Permission.Status] {
    var values = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0.rawValue, status($0)) })
    values["microphone"] = microphone()
    return values
  }

  /// What `command` declares and Wicket does not hold now.
  @MainActor func missing(_ command: ExtensionCommand) -> [Permission] {
    Self.missing(command, status: status)
  }

  static func missing(_ command: ExtensionCommand, status: (Permission) -> Permission.Status)
    -> [Permission]
  {
    command.manifest.permissions.filter { status($0) != .granted }
  }

  /// Whether `rows` are a gate's (`gate`).
  static func isGate(_ rows: [Result]) -> Bool {
    rows.first?.row.id.hasPrefix(rowPrefix) == true
  }
  private static let rowPrefix = "permission:"
  static let accessibilityRowID = rowID(.accessibility)

  private static func rowID(_ permission: Permission) -> String { rowPrefix + permission.rawValue }

  /// Wicket's own rows in place of the program's view while a declared permission is missing: one per
  /// permission, which asks for it where macOS lets Wicket ask, else opens its pane. `rerun` is the
  /// request the program did not get, which a Calendar grant follows. Nil when nothing is missing.
  @MainActor func gate(_ command: ExtensionCommand, rerun: Address) -> ProviderView? {
    let rows = command.manifest.permissions.compactMap {
      requestRow($0, neededBy: command.manifest.name, rerun: rerun)
    }
    return rows.isEmpty ? nil : ProviderView(items: rows)
  }

  @MainActor private func requestRow(_ permission: Permission, neededBy name: String, rerun: Address)
    -> Row?
  {
    let open = RowAction.open(permission.pane, title: "Open Privacy & Security")
    let subtitle: String
    let action: RowAction
    switch (permission, status(permission)) {
    case (_, .granted): return nil
    case (.accessibility, _):
      // An older grant can still show its switch on after an update or rebuild.
      subtitle = "\(name) needs it. If on, remove (–) and re-add Wicket."
      action = open
    case (.calendar, .askable):
      subtitle = "\(name) needs it"
      action = RowAction(.grant(.calendar, then: rerun), title: "Allow Calendar Access")
    case (.calendar, .denied):
      subtitle = "\(name) needs it. Turn on Wicket under Calendars"
      action = open
    }
    return Row(
      id: Self.rowID(permission), title: "Allow \(permission.title) for Wicket",
      subtitle: subtitle, icon: permission == .accessibility ? "lock" : "calendar", actions: [action])
  }
}
