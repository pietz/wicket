import AppKit
import WicketCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let index = AppIndex()
    private var palette: PaletteController!
    private let configDirectory = Settings.directory()
    private var settingsWatcher: FileWatcher?
    private var hotKey: HotKey?
    /// The shortcut `hotKey` holds; nil while none is registered, so the next change retries.
    private var registeredShortcut: Shortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = ContinuousClock.now
        palette = PaletteController()

        applySettings()
        settingsWatcher = FileWatcher(paths: [configDirectory.path], latency: 0.2) { [weak self] in
            self?.applySettings()
        }

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

    /// Loads settings.json (defaults if it is missing or invalid) and re-registers the hotkey if it changed.
    private func applySettings() {
        let url = configDirectory.appending(path: "settings.json")
        let settings: Settings
        do {
            settings = try Settings.load(from: url)
        } catch {
            let reason = String(describing: error)
            Perf.logger.error(
                "invalid \(url.path, privacy: .public), using defaults: \(reason, privacy: .public)")
            settings = Settings()
        }
        let shortcut = settings.hotkey
        guard shortcut != registeredShortcut else { return }
        hotKey = nil  // Unregister first: Carbon refuses a combination this app already holds.
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue) {
            [weak self] eventTime in
            self?.palette.toggle(eventTime: eventTime)
        }
        registeredShortcut = hotKey == nil ? nil : shortcut
        if hotKey == nil {
            Perf.logger.error("could not register hotkey \(shortcut, privacy: .public); another app owns it")
        } else {
            Perf.log("hotkey: \(shortcut)")
        }
    }

    private func publishItems() {
        var items: [PaletteItem] = []
        var alternates: [String: [String]] = [:]
        for app in index.apps {
            let id = app.url.path
            items.append(
                PaletteItem(
                    id: id, title: app.name, accessory: "Application", icon: .file(app.url),
                    action: .openApp(app.url)))
            alternates[id] = app.alternates
        }
        items.append(
            PaletteItem(
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
