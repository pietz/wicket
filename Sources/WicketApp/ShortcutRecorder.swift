import AppKit
import Carbon.HIToolbox
import Observation

/// A local raw-key monitor preserves Option keys and sees Command equivalents.
@MainActor
@Observable
final class ShortcutRecorder {
  private(set) var isRecording = false
  private(set) var rejected = false
  @ObservationIgnored private var monitor: Any?
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var pause: (Bool) -> Void = { _ in }

  func start(
    in window: NSWindow? = NSApp.keyWindow, pausing pause: @escaping (Bool) -> Void,
    onRecord: @escaping (Shortcut) -> Void
  ) {
    stop()
    isRecording = true
    self.pause = pause
    pause(true)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let keyCode = Int(event.keyCode)
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      MainActor.assumeIsolated {
        guard let self else { return }
        if keyCode == kVK_Escape, flags.isEmpty {
          self.stop()
        } else if let shortcut = Shortcut(keyCode: keyCode, modifiers: .init(flags)) {
          self.stop()
          onRecord(shortcut)
        } else {
          self.rejected = true
        }
      }
      return nil
    }
    observers = [
      observe(NSWindow.willCloseNotification, object: window),
      observe(NSApplication.didResignActiveNotification, object: nil),
    ]
  }
  private func observe(_ name: Notification.Name, object: Any?) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
  }

  func stop() {
    guard isRecording else { return }
    if let monitor { NSEvent.removeMonitor(monitor) }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    monitor = nil
    isRecording = false
    rejected = false
    pause(false)
  }
}

extension Shortcut.Modifiers {
  init(_ flags: NSEvent.ModifierFlags) {
    self = []
    if flags.contains(.command) { insert(.command) }
    if flags.contains(.control) { insert(.control) }
    if flags.contains(.option) { insert(.option) }
    if flags.contains(.shift) { insert(.shift) }
  }
}
