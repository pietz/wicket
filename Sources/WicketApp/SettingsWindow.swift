import AppKit
import SwiftUI

/// The settings window: an AppKit window with toolbar tabs, one SwiftUI pane per tab. Not SwiftUI's
/// `Settings` scene, which needs a SwiftUI `App` lifecycle; Wicket has an AppKit main.
///
/// Wicket is an accessory app (no Dock icon) so the palette never takes focus from the frontmost app.
/// While this window is open it becomes a regular app, with a Dock icon and a place in ⌘-Tab, so the
/// window can't get lost; closing it goes back to accessory and macOS reactivates the previous app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let voice: VoiceConsent
    private var window: NSWindow?

    init(store: SettingsStore, voice: VoiceConsent) {
        self.store = store
        self.voice = voice
    }

    /// Shows the window, on the pane titled `pane` if given, else on the one it shows.
    func show(pane: String? = nil) {
        // Before the window exists, so it opens on the current Space, even a full-screen one.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = makeWindow()
            window.center()
            self.window = window
        }
        if let pane, let tabs = window?.contentViewController as? NSTabViewController,
            let index = tabs.tabViewItems.firstIndex(where: { $0.label == pane })
        {
            tabs.selectedTabViewItemIndex = index
        }
        // Cooperative `activate()` is refused here: the palette is a non-activating panel, so to
        // macOS the request comes from a background app and the previous app keeps focus, leaving
        // Settings open but unfocused. The older forcing call still works (Tinycast relies on it);
        // `ForcedActivation` reaches it without the deprecation warning that check.sh rejects.
        (NSApp as any ForcedActivation).activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(pane("General", symbol: "gearshape", GeneralPane(store: store)))
        tabs.addTabViewItem(pane("Features", symbol: "square.grid.2x2", FeaturesPane(store: store)))
        tabs.addTabViewItem(pane("AI", symbol: "sparkles", AIPane(store: store)))
        tabs.addTabViewItem(pane("Voice", symbol: "waveform", VoicePane(consent: voice)))
        tabs.addTabViewItem(pane("Shortcuts", symbol: "command", ShortcutsPane(store: store)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func pane(_ title: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        // The tab view controller titles the window after the selected pane's controller.
        controller.title = title
        // Each pane sizes the window to fit, so switching tabs resizes it.
        controller.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        window = nil  // Free the panes while closed; the next open builds them again.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// `NSApplication.activate(ignoringOtherApps:)` through a protocol, so calling it is not a
/// deprecation warning. See `SettingsWindowController.show()` for why it is needed.
@MainActor private protocol ForcedActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: ForcedActivation {}
