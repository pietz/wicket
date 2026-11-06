import AppKit
import WicketCore
import WicketHost

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let apps = AppsSource()
    private let calculator = CalculatorSource()
    private let files = FilesSource()
    private let extensions = Extensions()
    private let registry = CommandRegistry()
    private var palette: PaletteController!
    private let store = SettingsStore(directory: Settings.directory())
    private lazy var settingsWindow = SettingsWindowController(store: store)
    private var settingsWatcher: FileWatcher?
    private var extensionsWatcher: FileWatcher?
    private var hotKey: HotKey?
    /// The shortcut `hotKey` holds; nil while none is registered, so the next change retries.
    private var registeredShortcut: Shortcut?
    /// True while the settings window records a new hotkey.
    private var hotKeyPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = ContinuousClock.now
        let effects = SystemEffects(extensions: extensions) { [weak self] in self?.settingsWindow.show() }
        palette = PaletteController(
            model: PaletteModel(sources: [apps, CommandsSource(registry), calculator, files]),
            dispatcher: ActionDispatcher(registry: registry, effects: effects))

        store.pauseHotKey = { [weak self] in self?.pauseHotKey($0) }
        applySettings()
        settingsWatcher = FileWatcher(paths: [store.url.deletingLastPathComponent().path], latency: 0.2) {
            [weak self] _ in
            self?.applySettings()
        }

        calculator.start { [weak self] in self?.palette.model.refresh() }
        extensions.load()
        registerExtensionCommands()
        extensionsWatcher = FileWatcher(paths: [extensions.directory.path], latency: 0.3) { [weak self] in
            self?.extensions.load(changed: $0)
            self?.registerExtensionCommands()
        }
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

    /// The switch for extension commands in the palette. They run without any approval until the
    /// consent store lands (refactor step 5b), so they stay out of the command registry, and with it
    /// out of the root search, keywords and `run` actions (which fail as "not found").
    private static let extensionCommandsInPalette = false

    private func registerExtensionCommands() {
        guard Self.extensionCommandsInPalette else { return }
        registry.setExtensionCommands(
            extensions.commands.map {
                RegisteredCommand(extension: $0.extensionID, command: $0.command, icon: $0.icon)
            })
        palette.model.refresh()
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
