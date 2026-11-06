import AppKit
// `@preconcurrency`: `kAXTrustedCheckOptionPrompt` is a C global var, read once as a constant.
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import WicketCore

/// The action dispatcher's side effects on this Mac: the one place where activating a result
/// touches the system.
@MainActor
final class SystemEffects: ActionEffects {
    /// How long a paste waits for its app to come to the front before it gives up.
    static let activationTimeout = Duration.seconds(1)
    /// How often the wait checks.
    static let activationPoll = Duration.milliseconds(10)
    /// The beat between the app being frontmost and ⌘V: the palette's key focus going back to the
    /// app's window isn't instant.
    static let settleDelay = Duration.milliseconds(50)

    private let showSettings: () -> Void
    private let messages: Messages
    /// Whether this session asked for Accessibility already, so a paste prompts at most once.
    private var promptedForAccessibility = false

    init(showSettings: @escaping () -> Void, messages: Messages) {
        self.showSettings = showSettings
        self.messages = messages
    }

    /// Doesn't wait for the app to launch: the palette closes at once.
    func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { Perf.logger.error("open failed: \(error)") }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies `text`, then, once the palette has closed (the dispatcher's `close` hides it in this
    /// same main-actor turn, before the task runs), brings `app` to the front and presses ⌘V there.
    /// The text stays on the clipboard afterwards: restoring what was there would mean reading the
    /// clipboard first, which macOS (15.4 on) treats as a programmatic read and asks the user about,
    /// and it would race the app's own read of the pasteboard. Every fallback is the copy plus a
    /// message (`PastePlan`). Accessibility is checked here, on a paste, never at launch.
    func paste(_ text: String, into app: RunningApp?) {
        copy(text)
        let running = app.flatMap(Self.running)
        let plan = PastePlan.decide(
            target: app, isRunning: running != nil, isTrusted: AXIsProcessTrusted(),
            hasPrompted: promptedForAccessibility)
        Task {
            switch plan {
            case .paste(let target):
                guard let running else { return }
                await paste(into: running, target)
            case .copyOnly(let fallback):
                fallBack(fallback)
            }
        }
    }

    /// The running app `app` names, unless it quit (or its process id now belongs to another app).
    private static func running(_ app: RunningApp) -> NSRunningApplication? {
        guard let running = NSRunningApplication(processIdentifier: app.processID), !running.isTerminated,
            running.bundleIdentifier == app.bundleID
        else { return nil }
        return running
    }

    private func paste(into running: NSRunningApplication, _ target: RunningApp) async {
        let start = ContinuousClock.now
        if !running.isActive { running.activate() }
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            guard ContinuousClock.now - start < Self.activationTimeout, !running.isTerminated else {
                fallBack(running.isTerminated ? .targetQuit(target) : .notFrontmost(target))
                return
            }
            try? await Task.sleep(for: Self.activationPoll)
        }
        try? await Task.sleep(for: Self.settleDelay)
        // The wait gave the user a moment to switch away; never type into another app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier else {
            fallBack(.notFrontmost(target))
            return
        }
        Self.pressCommandV()
        Perf.log("paste: \(Perf.ms(since: start)) to ⌘V")
    }

    private func fallBack(_ fallback: PasteFallback) {
        messages.post(Message(fallback.message, kind: .copied))
        guard case .notTrusted(prompt: true) = fallback else { return }
        promptedForAccessibility = true
        // The system's dialog, which lists Wicket in Privacy & Security > Accessibility and offers to
        // open it; the HUD behind it says why.
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Posts ⌘ plus the key that types V on the current layout (`KeyLookup`), with only ⌘ set, so
    /// a modifier still held from the palette's own chord (⌘↩) changes nothing.
    private static func pressCommandV() {
        let key = KeyLookup.keyCode(
            typing: "v", preferring: UInt16(kVK_ANSI_V),
            in: [
                TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource,
            ]
            .compactMap { KeyboardLayout($0()?.takeRetainedValue()) }.map { layout in
                { layout.text(typedBy: $0, modifiers: UInt32(cmdKey >> 8)) }
            })
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
                return
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSettings() {
        showSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

/// A keyboard layout's key map (`UCKeyTranslate`, the one API that answers which key types what;
/// nothing newer covers it).
private struct KeyboardLayout {
    /// Retained with the layout data, which it owns.
    private let source: TISInputSource
    private let data: CFData

    init?(_ source: TISInputSource?) {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        self.source = source
        data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// The text `keyCode` types with `modifiers` (Carbon modifier bits shifted right by 8), dead
    /// keys off; nil if none.
    func text(typedBy keyCode: UInt16, modifiers: UInt32) -> String? {
        withExtendedLifetime(source) {
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length,
                    &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}
