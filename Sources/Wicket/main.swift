import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let index = AppIndex()
    private var palette: PaletteController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = ContinuousClock.now
        palette = PaletteController()

        // ⌥Space. Configurable shortcuts come later.
        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] eventTime in
            self?.palette.toggle(eventTime: eventTime)
        }
        if hotKey == nil { Perf.logger.error("could not register ⌥Space; another app owns it") }

        index.onChange = { [weak self] in self?.publishItems() }
        Task {
            await index.start()
            Perf.log("launch→indexed: \(Perf.ms(since: launchStart))")
        }

        if !CommandLine.arguments.contains("--background") { palette.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        palette.show()
        return false
    }

    private func publishItems() {
        var items: [PaletteItem] = []
        var alternates: [String: [String]] = [:]
        for app in index.apps {
            let id = app.url.path
            items.append(PaletteItem(
                id: id, title: app.name, accessory: "Application", icon: .file(app.url),
                action: .openApp(app.url)))
            alternates[id] = app.alternates
        }
        items.append(PaletteItem(
            id: "wicket.quit", title: "Quit Wicket", accessory: "Command", icon: .symbol("power"),
            action: .quit))
        palette.model.setItems(items, alternates: alternates)
        // Warm the icons the empty palette shows first, off the summon path.
        for item in palette.model.results.prefix(12) { _ = IconCache.image(for: item.icon) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
