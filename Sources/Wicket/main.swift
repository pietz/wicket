import AppKit
import WicketCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let apps = AppsSource()
    private let calculator = CalculatorSource()
    private let files = FilesSource()
    private let extensions = Extensions()
    private var palette: PaletteController!
    private let store = SettingsStore(directory: Settings.directory())
    private lazy var settingsWindow = SettingsWindowController(store: store)
    private var settingsWatcher: FileWatcher?
    private var hotKey: HotKey?
    /// The shortcut `hotKey` holds; nil while none is registered, so the next change retries.
    private var registeredShortcut: Shortcut?
    /// True while the settings window records a new hotkey.
    private var hotKeyPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = ContinuousClock.now
        let commands = CommandsSource([
            .init(id: "settings", title: "Wicket Settings", symbol: "gearshape") { [weak self] in
                self?.settingsWindow.show()
            },
            .init(id: "quit", title: "Quit Wicket", symbol: "power") { NSApp.terminate(nil) },
        ])
        palette = PaletteController(
            model: PaletteModel(sources: [apps, commands, calculator, files]),
            actions: ActionRunner(commands: commands),
            openSettings: { [weak self] in self?.settingsWindow.show() })

        store.pauseHotKey = { [weak self] in self?.pauseHotKey($0) }
        applySettings()
        settingsWatcher = FileWatcher(paths: [store.url.deletingLastPathComponent().path], latency: 0.2) {
            [weak self] _ in
            self?.applySettings()
        }

        calculator.start { [weak self] in self?.palette.model.refresh() }
        extensions.start()
        apps.onChange = { [weak self] in self?.palette.model.refresh() }
        Task {
            await apps.start()
            Perf.log("launch→indexed: \(Perf.ms(since: launchStart))")
        }

        if !CommandLine.arguments.contains("--background") { palette.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        palette.show()
        return false
    }

    /// Reloads settings.json (defaults if it is missing or invalid) and re-registers the hotkey if it
    /// changed.
    private func applySettings() {
        store.reload()
        palette.width = store.settings.paletteWidth
        let shortcut = store.settings.hotkey
        guard !hotKeyPaused, shortcut != registeredShortcut else { return }
        hotKey = nil  // Unregister first: Carbon refuses a combination this app already holds.
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue) {
            [weak self] eventTime in
            self?.palette.toggle(eventTime: eventTime)
        }
        registeredShortcut = hotKey == nil ? nil : shortcut
        store.hotKeyFailed = hotKey == nil
        if hotKey == nil {
            Perf.logger.error("could not register hotkey \(shortcut, privacy: .public); another app owns it")
        } else {
            Perf.log("hotkey: \(shortcut)")
        }
    }

    private func pauseHotKey(_ paused: Bool) {
        hotKeyPaused = paused
        if paused {
            hotKey = nil
            registeredShortcut = nil
        } else {
            applySettings()
        }
    }

}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
