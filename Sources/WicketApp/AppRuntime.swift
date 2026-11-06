import AppKit
import WicketCore
import WicketHost

/// What the runtime drives in the palette window: `PaletteController`, a fake in tests.
@MainActor
protocol PaletteSurface: AnyObject {
    /// The pill's width; applied on the next summon.
    var width: CGFloat { get set }
    func show(eventTime: TimeInterval)
    func toggle(eventTime: TimeInterval)
    /// Runs a command bound to a global hotkey.
    func run(bound: CommandID)
}

extension PaletteController: PaletteSurface {}

/// The running app: its parts composed, and settings.json applied to them.
///
/// Settings are applied as one snapshot (`apply`), in the order that keeps everything that depends
/// on them coherent: first the registry (which built-ins exist, which aliases name what), then the
/// runs of commands that left it stop, then the root's sources, then one fresh root search if
/// either changed (so what is on screen shows the new aliases and features at once), then the work
/// behind features starts or stops, and last the hotkeys, resolved against the new registry. The
/// palette's width and the AI provider are read on use (next summon, next answer).
///
/// What touches the system (hotkey registration, file watching, the work behind features) comes in
/// through `System` and `Work`, so tests apply settings without registering a real hotkey.
@MainActor
final class AppRuntime {
    /// The side-effecting seams: the app's register Carbon hotkeys and watch with FSEvents.
    struct System {
        var registerHotKey: RegisterHotKey
        /// Calls `onChange` with the changed folders when anything under `paths` changes, until the
        /// returned object is released.
        var watch:
            (_ paths: [String], _ latency: TimeInterval, _ onChange: @escaping @MainActor ([String]) -> Void)
                ->
                AnyObject?
    }

    /// What a feature runs between queries (the app scan, the exchange rates): started while the
    /// feature is on, stopped when it is turned off.
    struct Work {
        var start: @MainActor () -> Void
        var stop: @MainActor () -> Void
    }

    /// The switch for extension commands in the palette. They run without any approval until the
    /// consent store lands (refactor step 5b), so they stay out of the command registry, and with it
    /// out of the root search, keywords and `run` actions (which fail as "not found"), and root-mode
    /// commands get no root source. Everything else (command frames, the runner) is wired either way.
    static let extensionCommandsInPalette = false

    let store: SettingsStore
    let registry = CommandRegistry()
    let model: PaletteModel
    /// The palette window, once composed; hotkeys and settings reach it through here.
    var palette: (any PaletteSurface)?
    /// Opens the settings window.
    var showSettings: () -> Void = {}

    private let extensions: Extensions
    private let askAI: AskAIRunner
    /// Every root source, before settings.json turns features off.
    private let allSources: [any ResultSource]
    private let work: [Feature: Work]
    private let hotKeys: HotKeys
    private let system: System
    private var watchers: [AnyObject] = []
    /// The settings last applied; nil before the first `apply`.
    private(set) var applied: Settings?

    /// `sources` are the host's own root sources (apps, calculator, files); the runtime adds the
    /// registry's commands, Ask AI's row and, behind the switch, the extensions' root commands.
    init(
        store: SettingsStore, sources: [any ResultSource], work: [Feature: Work], askAI: AskAIRunner,
        extensions: Extensions, usageURL: URL = PaletteModel.defaultUsageURL, system: System
    ) {
        self.store = store
        self.extensions = extensions
        self.askAI = askAI
        self.work = work
        self.system = system
        var sources = sources + [CommandsSource(registry), AskAISource(registry: registry)]
        if Self.extensionCommandsInPalette { sources.append(ExtensionRootSource(extensions)) }
        allSources = sources
        let runner = CommandRouter(builtins: [AskAI.command: askAI], extensions: extensions)
        // `apply` drops the sources of features that are off before the palette first shows.
        model = PaletteModel(sources: sources, runner: runner, registry: registry, usageURL: usageURL)
        hotKeys = HotKeys(register: system.registerHotKey)
        hotKeys.onPalette = { [weak self] in self?.palette?.toggle(eventTime: $0) }
        hotKeys.onCommand = { [weak self] in self?.palette?.run(bound: $0) }
        store.pauseHotKey = { [weak self] in self?.pauseHotKeys($0) }
    }

    /// Applies settings.json and keeps applying it as it changes, and loads the extensions.
    func start() {
        reload()
        let settingsFolder = store.url.deletingLastPathComponent().path
        watch([settingsFolder], latency: 0.2) { [weak self] _ in self?.reload() }

        extensions.load()
        registerExtensionCommands()
        watch([extensions.directory.path], latency: 0.3) { [weak self] in
            self?.extensions.load(changed: $0)
            self?.registerExtensionCommands()
        }
    }

    func showPalette() {
        palette?.show(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    /// Reloads settings.json (defaults if it is missing or invalid) and applies it.
    func reload() {
        store.reload()
        apply(store.settings)
    }

    /// Applies one settings snapshot, in the order the type's comment gives.
    func apply(_ settings: Settings) {
        let previous = applied
        applied = settings
        palette?.width = CGFloat(settings.paletteWidth)
        askAI.provider = settings.ai.provider

        let revision = registry.revision
        registry.setDisabledBuiltins(Set(settings.disabledFeatures.flatMap(\.commands)))
        registry.setAliases(settings.commands.compactMapValues(\.alias))
        let refreshed = model.session.setSources(Feature.enabled(allSources, in: settings))
        registryChanged(since: revision, refreshed: refreshed)

        // Nothing runs before the first snapshot, so it only starts work.
        for feature in Feature.allCases {
            guard let work = work[feature],
                (previous?.isEnabled(feature) ?? false) != settings.isEnabled(feature)
            else { continue }
            if settings.isEnabled(feature) { work.start() } else { work.stop() }
        }
        if previous?.disabledFeatures != settings.disabledFeatures {
            Perf.log("features off: \(settings.disabledFeatures.map(\.rawValue).sorted())")
        }
        applyHotKeys(settings)
    }

    /// After something that may have changed the registry: the runs of commands no longer in it
    /// stop (Ask AI turned off mid-answer, an extension removed), and the root searches again unless
    /// it just did, so a new alias or a command gone shows at once.
    private func registryChanged(since revision: Int, refreshed: Bool) {
        guard registry.revision != revision else { return }
        model.session.stopCommands { [registry] in registry.command($0) == nil }
        if !refreshed { model.refresh() }
    }

    /// Registers the hotkeys for `settings` against the current registry, and tells the panes.
    private func applyHotKeys(_ settings: Settings) {
        hotKeys.apply(settings, registry: registry)
        store.hotKeyFailed = hotKeys.paletteFailed
        store.bindingProblems = hotKeys.problems(registry)
        store.commands = registry.commands
    }

    /// Stops every global hotkey while the settings window records one; when it is done, settings
    /// are reloaded, so a hotkey it just wrote is registered at once.
    private func pauseHotKeys(_ paused: Bool) {
        hotKeys.paused = paused
        if paused {
            applyHotKeys(applied ?? store.settings)
        } else {
            reload()
        }
    }

    private func registerExtensionCommands() {
        guard Self.extensionCommandsInPalette else { return }
        let revision = registry.revision
        registry.setExtensionCommands(
            extensions.commands.map {
                RegisteredCommand(extension: $0.extensionID, command: $0.command, icon: $0.icon)
            })
        registryChanged(since: revision, refreshed: false)
        applyHotKeys(applied ?? store.settings)  // A binding waiting for one of them takes effect.
    }

    private func watch(
        _ paths: [String], latency: TimeInterval, _ onChange: @escaping @MainActor ([String]) -> Void
    ) {
        if let watcher = system.watch(paths, latency, onChange) { watchers.append(watcher) }
    }
}

// MARK: The app's parts

extension AppRuntime.System {
    /// Carbon hotkeys and FSEvents.
    @MainActor static var live: AppRuntime.System {
        AppRuntime.System(
            registerHotKey: { shortcut, handler in
                HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue, handler: handler)
            },
            watch: { paths, latency, onChange in
                FileWatcher(paths: paths, latency: latency, onChange: onChange)
            })
    }
}

extension AppRuntime {
    /// The app as it runs: the real sources, the palette window and the settings window.
    static func live() -> AppRuntime {
        let launchStart = ContinuousClock.now
        var logLaunch = true
        let apps = AppsSource()
        let calculator = CalculatorSource()
        let store = SettingsStore(directory: Settings.directory())
        weak var weakRuntime: AppRuntime?
        let work: [Feature: Work] = [
            .apps: Work(
                start: {
                    Task {
                        await apps.start()
                        guard logLaunch else { return }
                        logLaunch = false
                        Perf.log("launch→indexed: \(Perf.ms(since: launchStart))")
                    }
                },
                stop: apps.stop),
            .calculator: Work(
                start: { calculator.start { weakRuntime?.model.refresh() } }, stop: calculator.stop),
        ]
        let runtime = AppRuntime(
            store: store, sources: [apps, calculator, FilesSource()], work: work, askAI: AskAIRunner(),
            extensions: Extensions(), system: .live)
        weakRuntime = runtime
        apps.onChange = { [weak runtime] in runtime?.model.refresh() }

        let settingsWindow = SettingsWindowController(store: store)
        weak var weakPalette: PaletteController?
        let effects = SystemEffects(
            showSettings: { settingsWindow.show() },
            showMessage: { weakPalette?.showHUD($0, symbol: $1) })
        let palette = PaletteController(
            model: runtime.model, dispatcher: ActionDispatcher(registry: runtime.registry, effects: effects))
        weakPalette = palette
        runtime.palette = palette
        runtime.showSettings = { settingsWindow.show() }
        return runtime
    }
}
