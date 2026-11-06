import AppKit
import Carbon.HIToolbox
import WicketCore

/// Records one key combination for a hotkey field.
///
/// An AppKit local event monitor, not SwiftUI's `onKeyPress`: that reports characters (⌥A arrives as
/// "å") and never sees ⌘ combinations the window handles as key equivalents. The monitor sees the
/// raw key code and modifiers before anything else and swallows the press.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// The last press can't be a hotkey (no ⌘, ⌃ or ⌥), so recording goes on.
    private(set) var rejected = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pause: (Bool) -> Void = { _ in }

    /// Calls `onRecord` with the first valid combination; plain Escape cancels, and so does leaving
    /// the app. `pause` is called with true now and false when recording ends, after `onRecord`.
    func start(pausing pause: @escaping (Bool) -> Void, onRecord: @escaping (Shortcut) -> Void) {
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
                    onRecord(shortcut)
                    self.stop()
                } else {
                    self.rejected = true
                }
            }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
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
