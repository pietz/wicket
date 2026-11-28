import AppKit
import Carbon.HIToolbox
import Observation

/// A local raw-key monitor preserves Option keys and sees Command equivalents.
@MainActor
@Observable
final class ShortcutRecorder {
  private(set) var isRecording = false
  private(set) var rejected = false
  /// The binding `record` is recording, until it stops.
  private(set) var target: HotkeyTarget?
  @ObservationIgnored private var monitor: Any?
  @ObservationIgnored private var onRecord: ((Shortcut) -> Void)?
  @ObservationIgnored private var onRemove: (() -> Void)?
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var pause: (Bool) -> Void = { _ in }

  func start(
    in window: NSWindow? = NSApp.keyWindow, pausing pause: @escaping (Bool) -> Void,
    onRemove: (() -> Void)? = nil, onRecord: @escaping (Shortcut) -> Void
  ) {
    stop()
    isRecording = true
    self.pause = pause
    pause(true)
    self.onRecord = onRecord
    self.onRemove = onRemove
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let keyCode = Int(event.keyCode)
      let modifiers = Shortcut.Modifiers(event.modifierFlags)
      MainActor.assumeIsolated { self?.keyPressed(keyCode, modifiers: modifiers) }
      return nil
    }
    observers = [
      observe(NSWindow.willCloseNotification, object: window),
      observe(NSApplication.didResignActiveNotification, object: nil),
    ]
  }
  /// The next shortcut pressed becomes the launcher's hotkey (no target) or `target`'s, under the
  /// launcher's rules (`ConfigurationStore.bind`): Settings and the panel's Set Hotkey… alike. The last
  /// recording's rejection goes as this one starts.
  func record(
    _ target: HotkeyTarget?, in window: NSWindow? = NSApp.keyWindow, store: ConfigurationStore,
    pausing pause: @escaping (Bool) -> Void
  ) {
    store.rejection = nil
    let remove: (() -> Void)? = target.map { target in { store.bind(nil, to: target) } }
    start(in: window, pausing: pause, onRemove: remove) { keys in
      if let target { store.bind(keys, to: target) } else { store.setHotkey(keys) }
    }
    self.target = target
  }
  func keyPressed(_ code: Int, modifiers: Shortcut.Modifiers) {
    guard let onRecord else { return }
    if code == kVK_Escape, modifiers.isEmpty {
      stop()
    } else if code == kVK_Delete, modifiers.isEmpty, let onRemove {
      stop()
      onRemove()
    } else if let shortcut = Shortcut(keyCode: code, modifiers: modifiers) {
      stop()
      onRecord(shortcut)
    } else {
      rejected = true
    }
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
    onRecord = nil
    onRemove = nil
    isRecording = false
    rejected = false
    target = nil
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
