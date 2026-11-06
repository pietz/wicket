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
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        // Before the window exists, so it opens on the current Space, even a full-screen one.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = makeWindow()
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(pane("General", symbol: "gearshape", GeneralPane(store: store)))
        tabs.addTabViewItem(pane("AI", symbol: "sparkles", AIPane(store: store)))
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
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

/// Wicket has no main menu (it never shows a menu bar of its own), so ⌘W is handled here.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "w"
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
