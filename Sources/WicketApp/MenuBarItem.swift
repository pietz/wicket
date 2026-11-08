import AppKit
import WicketCore

/// What the runtime drives in the menu bar: `MenuBarItem`, a fake in tests.
@MainActor
protocol MenuBarSurface: AnyObject {
    /// Shows or hides the icon; `hotkey` is the palette's hotkey while it is in effect, shown beside
    /// Open Wicket.
    func update(visible: Bool, hotkey: Shortcut?)
}

/// Wicket's menu bar icon, so a running Wicket can be seen and reached without its hotkey: Open
/// Wicket, Settings…, Check for Updates… (the released app only) and Quit Wicket. Its items call the same paths as the hotkey and ⌘, (the
/// runtime's `showPalette` and `showSettings`), so it holds no state of its own.
///
/// The status item is created the first time it is shown and only hidden after that, so nothing
/// here runs on the palette's path.
@MainActor
final class MenuBarItem: NSObject, MenuBarSurface {
    private let onOpen: () -> Void
    private let onSettings: () -> Void
    private let updater: Updater?
    private var statusItem: NSStatusItem?
    private let openItem = NSMenuItem(title: "Open Wicket", action: #selector(open), keyEquivalent: "")

    init(onOpen: @escaping () -> Void, onSettings: @escaping () -> Void, updater: Updater?) {
        self.onOpen = onOpen
        self.onSettings = onSettings
        self.updater = updater
    }

    func update(visible: Bool, hotkey: Shortcut?) {
        if visible, statusItem == nil { statusItem = makeStatusItem() }
        statusItem?.isVisible = visible
        // The hint only: the global hotkey (Carbon) is what runs it outside the menu.
        openItem.keyEquivalent = hotkey?.keyEquivalent ?? ""
        openItem.keyEquivalentModifierMask = hotkey?.modifierFlags ?? []
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // SF Symbols are template images, so the icon follows the menu bar's appearance.
        item.button?.image = NSImage(
            systemSymbolName: "door.left.hand.open", accessibilityDescription: "Wicket")
        let menu = NSMenu()
        openItem.target = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.items = [openItem, settings]
        if updater != nil {
            let check = NSMenuItem(
                title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.items.append(check)
        }
        menu.items += [
            .separator(),
            NSMenuItem(
                title: "Quit Wicket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        item.menu = menu
        return item
    }

    @objc private func open() { onOpen() }
    @objc private func showSettings() { onSettings() }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
}

extension Shortcut {
    /// The key as an `NSMenuItem` key equivalent, so a menu shows the shortcut as its hint.
    var keyEquivalent: String {
        switch key {
        case "space": return " "
        case "return": return "\r"
        case "tab": return "\t"
        case "escape": return "\u{1b}"
        default:
            // F1 to F20 are consecutive in AppKit's function-key range.
            if key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()),
                let scalar = Unicode.Scalar(NSF1FunctionKey + number - 1)
            {
                return String(Character(scalar))
            }
            return key
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        let flags: [(Modifiers, NSEvent.ModifierFlags)] = [
            (.command, .command), (.shift, .shift), (.option, .option), (.control, .control),
        ]
        return flags.reduce(into: []) { result, pair in
            if modifiers.contains(pair.0) { result.insert(pair.1) }
        }
    }
}
