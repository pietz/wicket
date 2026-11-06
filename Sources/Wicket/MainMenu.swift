import AppKit

/// The main menu: the app, Edit and Window menus with their standard shortcuts. Built once at launch.
/// macOS shows it only while Wicket is a regular app, which is while the settings window is open; as
/// an accessory app it has no menu bar.
///
/// The palette never lets it act: AppKit offers a ⌘ key to the key window before the main menu, and
/// `PalettePanel` claims its own chords there and swallows every other key the menu binds, so ⌘Q,
/// ⌘W, ⌘H and ⌘M do nothing in the palette, as before the menu existed.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            submenu(
                "Wicket",
                [
                    item("About Wicket", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                    .separator(),
                    // Nil-targeted: the app delegate, at the end of the responder chain, opens it.
                    item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
                    .separator(),
                    item("Hide Wicket", #selector(NSApplication.hide(_:)), "h"),
                    .separator(),
                    item("Quit Wicket", #selector(NSApplication.terminate(_:)), "q"),
                ]))
        menu.addItem(
            submenu(
                "Edit",
                [
                    item("Undo", Selector(("undo:")), "z"),
                    item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                    .separator(),
                    item("Cut", #selector(NSText.cut(_:)), "x"),
                    item("Copy", #selector(NSText.copy(_:)), "c"),
                    item("Paste", #selector(NSText.paste(_:)), "v"),
                    item("Select All", #selector(NSText.selectAll(_:)), "a"),
                ]))
        let window = submenu(
            "Window",
            [
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.items = items
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Sent to the first responder: the focused field, the key window, then the app and its delegate.
    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

extension NSMenu {
    /// Whether an item in this menu or its submenus has `event`'s key and modifiers as its shortcut.
    func bindsKeyEquivalent(of event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        return items.contains { item in
            if let submenu = item.submenu { return submenu.bindsKeyEquivalent(of: event) }
            guard !item.keyEquivalent.isEmpty else { return false }
            var modifiers = item.keyEquivalentModifierMask
            // An uppercase key equivalent implies Shift.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            return item.keyEquivalent.lowercased() == key && modifiers == flags
        }
    }
}
