import AppKit
import WicketCore
import WicketHost

// Composes the app, applies settings snapshots and keeps commands, windows and OS services in sync.

/// What the runtime drives in the palette window: `PaletteController`, a fake in tests.
@MainActor
protocol PaletteSurface: AnyObject {
    /// The pill's width; applied on the next summon.
    var width: CGFloat { get set }
    func show(eventTime: TimeInterval)
    func toggle(eventTime: TimeInterval)
}

extension PaletteController: PaletteSurface {}

/// The running app: its parts composed, and settings.json applied to them.
///
/// Settings are applied as one snapshot (`apply`), in the order that keeps everything that depends
/// on them coherent: first the registry (whether the commands that use AI exist), then the runs of
/// commands that left it stop and the root searches again if it changed (so what is on screen
/// follows at once), then the hotkey, and last the menu bar icon, which shows the hotkey that is in
/// effect. The palette's width and the AI provider are read on use (next summon, next answer).
///
/// What touches the system (hotkey registration, file watching, the work behind the sources) comes
/// in through `System` and `work`, so tests apply settings without registering a real hotkey.
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

    let store: SettingsStore
    let registry: CommandRegistry
    let model: PaletteModel
    /// The one channel for transient messages: the session's command messages and the paste
    /// effect's post here, and the palette controller presents them.
    let messages = Messages()
    /// Where every problem is reported, the panes' and the extensions' alike (`store.diagnostics`).
    var diagnostics: Diagnostics { store.diagnostics }
    /// The palette window, once composed; hotkeys and settings reach it through here.
    var palette: (any PaletteSurface)?
    /// The menu bar icon, once composed; settings show or hide it.
    var menuBar: (any MenuBarSurface)?
    /// Opens the settings window.
    var showSettings: () -> Void = {}

    /// Discovery and the active catalog: only approved revisions, whose commands the registry
    /// takes on every published snapshot.
    let extensions: Extensions
    /// Every command's runner (built-ins and extensions), which `shutdown` stops.
    private let runner: CommandRouter
    /// The one shutdown, once begun.
    private var stopping: Task<Void, Never>?
    /// What the sources run between queries (the app scan, the exchange rates), started once.
    private let work: [@MainActor () -> Void]
    private let hotKey: PaletteHotKey
    private let system: System
    private var watchers: [AnyObject] = []
    /// The settings last applied; nil before the first `apply`.
    private(set) var applied: Settings?

    /// `sources` are the host's own root sources (apps, calculator, files); the runtime adds the
    /// registry's commands and its fallback rows.
    /// `builtins` is the table of Wicket's own commands (`live()` composes it): the registry takes
    /// their commands, the router their runners. The runtime adds Load Images, which acts on its
    /// palette model.
    init(
        store: SettingsStore, sources: [any ResultSource], work: [@MainActor () -> Void], builtins: [Builtin],
        extensions: Extensions, usageURL: URL = PaletteModel.defaultUsageURL, system: System
    ) {
        weak var weakModel: PaletteModel?
        // Load Images on a page while "Show online content" is off: the page its args name loads
        // its web images; reached by id only, from the screen's actions (`PaletteModel.target`).
        let builtins =
            builtins + [
                Builtin(
                    RegisteredCommand(
                        id: .loadImages, title: "Load Images", icon: .symbol(name: "photo"), isListed: false,
                        input: .none),
                    staying: { weakModel?.loadImages($0) })
            ]
        self.store = store
        self.extensions = extensions
        registry = CommandRegistry(builtins: builtins.map(\.command))
        self.work = work
        self.system = system
        let sources =
            sources + [CommandsSource(registry), FallbackSource(registry)]
        let runner = CommandRouter(builtins: builtins, extensions: extensions)
        self.runner = runner
        model = PaletteModel(
            sources: sources, runner: runner, registry: registry, messages: messages, usageURL: usageURL)
        weakModel = model
        hotKey = PaletteHotKey(register: system.registerHotKey)
        hotKey.onPress = { [weak self] in self?.palette?.toggle(eventTime: $0) }
        store.pauseHotKey = { [weak self] in self?.pauseHotKey($0) }
    }

    /// Applies settings.json and keeps applying it as it changes, starts the sources' work and loads
    /// the extensions.
    func start() {
        reload()
        for start in work { start() }
        let settingsFolder = store.url.deletingLastPathComponent().path
        watch([settingsFolder], latency: 0.2) { [weak self] _ in self?.reload() }

        // Discovery runs off the main actor; each published snapshot registers the catalog.
        extensions.onChange = { [weak self] in self?.registerExtensionCommands() }
        extensions.load()
        watch([extensions.directory.path], latency: 0.3) { [weak self] in self?.extensions.load(changed: $0) }
    }

    /// Stops what runs outside the app before it quits: every command's runs, Run Agent's agents and
    /// extension runs, each through its process tree. Returns once all are gone, or after `limit` (quitting must not hang on a process that won't die). Runs once
    /// however often it's called.
    func shutdown(within limit: Duration = .seconds(2)) async {
        let start = ContinuousClock.now
        let stopping =
            stopping
            ?? Task { [model, runner] in
                _ = model.session.stopCommands { _ in true }
                await runner.shutdown()
            }
        self.stopping = stopping
        let done = await stopping.value(within: limit) != nil
        Perf.log("shutdown: \(done ? "done" : "gave up") after \(Perf.ms(since: start))")
    }

    func showPalette() {
        palette?.show(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    /// Reloads settings.json (defaults if missing, the last good settings if invalid) and applies it.
    func reload() {
        store.reload()
        apply(store.settings)
    }

    /// Applies one settings snapshot, in the order the type's comment gives.
    func apply(_ settings: Settings) {
        applied = settings
        palette?.width = CGFloat(settings.paletteWidth)
        model.textSize = settings.textSize
        model.showsOnlineContent = settings.showOnlineContent

        let changes = registry.changes
        registry.setAIEnabled(settings.ai.enabled)
        registryChanged(since: changes)
        applyHotKey(settings.hotkey)
        menuBar?.update(visible: settings.showInMenuBar, hotkey: hotKey.inEffect)
    }

    /// After something that may have changed the registry: the runs of commands no longer in it
    /// stop (Run Agent turned off mid-answer, an extension removed), runs bound to a revision their
    /// command no longer has stop saying the extension changed (`PaletteSession.rebind`; nothing
    /// reruns by itself), keyword conflicts are reported, and the root searches again, so a command
    /// gone shows at once.
    private func registryChanged(since changes: Int) {
        guard registry.changes != changes else { return }
        model.session.stopCommands { [registry] in registry.command($0) == nil }
        model.session.rebind { [registry] in registry.command($0) }
        let title = { [registry] (id: CommandID) in registry.command(id)?.title ?? id.description }
        diagnostics.replace(
            .conflict,
            with: registry.keywordConflicts.map {
                Diagnostic(
                    .command($0.loser), .conflict, .warning,
                    "The keyword \($0.keyword) is already \(title($0.winner))'s.")
            })
        model.refresh()
    }

    /// Registers the palette's hotkey and reports it to the diagnostics the General pane reads when
    /// it isn't in effect.
    private func applyHotKey(_ shortcut: Shortcut) {
        hotKey.apply(shortcut)
        diagnostics.replace(
            .hotkey, with: hotKey.problem.map { [Diagnostic(.hotkey, .hotkey, .error, $0)] } ?? [])
    }

    /// Releases the hotkey while the settings window records one; when it is done, settings are
    /// reloaded, so a hotkey it just wrote is registered at once.
    private func pauseHotKey(_ paused: Bool) {
        hotKey.paused = paused
        if paused {
            applyHotKey((applied ?? store.settings).hotkey)
        } else {
            reload()
        }
    }

    /// Registers the active catalog's commands (approved revisions only) after each published
    /// discovery: an approval, a revoke or a folder change. Runs of commands gone stop and runs bound
    /// to a replaced revision are reconciled.
    private func registerExtensionCommands() {
        let changes = registry.changes
        registry.setExtensionCommands(extensions.commands)
        registryChanged(since: changes)
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
        let apps = AppsSource()
        let calculator = CalculatorSource()
        let diagnostics = Diagnostics()
        let store = SettingsStore(directory: Settings.directory(), diagnostics: diagnostics)
        // Whether Wicket may listen is consent, kept outside settings.json (VoiceConsent).
        let voiceConsent = VoiceConsent()
        let voice = VoiceInput(consent: voiceConsent) { AppleTranscriber() }
        // Sparkle, for the released app only (nil in Wicket Dev).
        let updater = Updater()
        let settingsWindow = SettingsWindowController(
            store: store, voice: voiceConsent, updater: updater)
        weak var weakRuntime: AppRuntime?
        // What may run is the approved revisions, recorded in a host file only Wicket's screens write.
        let extensions = Extensions(
            directory: ExtensionPaths.extensions, store: RevisionStore(root: ExtensionPaths.revisions),
            approvals: Approvals(), diagnostics: diagnostics,
            history: ExtensionHistory(root: ExtensionPaths.history))
        let consent = ExtensionsRunner(extensions: extensions)
        // Every AI run. Runs know Wicket's commands and write extensions into its folder for review.
        let runAgent = AgentRunner(provider: { weakRuntime?.applied?.ai.provider })
        runAgent.authoring = ExtensionAuthoring(
            extensions: extensions, commands: { weakRuntime?.registry.commands ?? [] },
            instructionsFile: ExtensionAuthoring.instructionsFile, commandList: ExtensionPaths.commandList)
        runAgent.options = { weakRuntime?.applied?.ai[$0] ?? $0.defaultOptions }
        let work: [@MainActor () -> Void] = [
            {
                Task {
                    await apps.start()
                    Perf.log("launch→indexed: \(Perf.ms(since: launchStart))")
                }
            },
            { calculator.start { weakRuntime?.model.refresh() } },
        ]
        // Wicket's own commands: each is one entry, its registration and its runner. Search, keywords
        // and its frame come from the registry and the invocation policy.
        let builtins = [
            Builtin(
                RegisteredCommand(
                    id: .settings, title: "Wicket Settings", icon: .symbol(name: "gearshape"),
                    search: ["settings", "preferences"], input: .none),
                effect: { settingsWindow.show() }),
            Builtin(
                RegisteredCommand(
                    id: .builtin("quit"), title: "Quit Wicket", icon: .symbol(name: "power"), input: .none),
                effect: { NSApp.terminate(nil) }),
            // Answers a question or does what it asks with the user's agent CLI, building or changing
            // Wicket's own commands included. Its keyword `ai` (a built-in keeps it against
            // extensions) opens its frame waiting for the question; the root offers it as a fallback
            // row for whatever was typed.
            Builtin(
                RegisteredCommand(
                    id: .runAgent, title: "Run Agent", icon: .symbol(name: "sparkles"), keyword: "ai",
                    isListed: false, input: .submitText, placeholder: "Ask or tell the agent",
                    isFallback: true, usesAI: true, usesContext: true),
                runner: runAgent),
            // Follow Up under a Run Agent answer: its frame waits for the next question, which
            // continues the same conversation with the agent; reached by id only.
            Builtin(
                RegisteredCommand(
                    id: .followUp, title: "Follow Up", icon: .symbol(name: "sparkles"), isListed: false,
                    input: .submitText, placeholder: "Follow up", usesAI: true),
                runner: runAgent),
            // Answers an acting agent's approval shown in a Run Agent frame; reached by id only.
            Builtin(
                RegisteredCommand(
                    id: .aiApproval, title: "Answer the Agent", icon: .symbol(name: "sparkles"),
                    isListed: false, input: .none),
                runner: runAgent),
            // Run Agent's action when no provider is ready; reached by id only.
            Builtin(
                RegisteredCommand(
                    id: .aiSettings, title: "AI Settings", icon: .symbol(name: "sparkles"), isListed: false,
                    input: .none),
                effect: { settingsWindow.show(pane: "AI") }),
            // Every discovered extension with its state; reviewing, enabling and disabling one are
            // the hidden built-ins below, reached only by the actions its screens draw.
            Builtin(
                RegisteredCommand(
                    id: .extensions, title: "Extensions", icon: .symbol(name: "puzzlepiece.extension"),
                    keyword: "extensions"),
                runner: consent),
            Builtin(
                RegisteredCommand(
                    id: .reviewExtension, title: "Review Extension", icon: .symbol(name: "checkmark.shield"),
                    isListed: false, input: .none),
                runner: consent),
            Builtin(
                RegisteredCommand(
                    id: .enableExtension, title: "Enable Extension", icon: .symbol(name: "checkmark.circle"),
                    isListed: false, input: .none),
                runner: consent),
            Builtin(
                RegisteredCommand(
                    id: .disableExtension, title: "Disable Extension", icon: .symbol(name: "xmark.circle"),
                    isListed: false, input: .none),
                runner: consent),
            Builtin(
                RegisteredCommand(
                    id: .trashExtension, title: "Move Extension to Trash", icon: .symbol(name: "trash"),
                    isListed: false, input: .none),
                runner: consent),
            Builtin(
                RegisteredCommand(
                    id: .setSecret, title: "Set Secret", icon: .symbol(name: "key"), isListed: false,
                    input: .submitText, placeholder: "Paste the value and press Return"),
                runner: SecretsRunner(extensions: extensions)),
        ]
        let runtime = AppRuntime(
            store: store, sources: [apps, calculator, FilesSource(), LinkSource()], work: work,
            builtins: builtins, extensions: extensions, system: .live)
        weakRuntime = runtime
        apps.onChange = { [weak runtime] in runtime?.model.refresh() }

        let effects = SystemEffects(messages: runtime.messages)
        let palette = PaletteController(
            model: runtime.model, dispatcher: ActionDispatcher(registry: runtime.registry, effects: effects))
        runtime.palette = palette
        runtime.model.voice = voice
        voice.write = { [weak runtime] in runtime?.model.session.setSpokenQuery($0) ?? false }
        voice.fail = { [weak runtime] in runtime?.messages.post(Message($0, kind: .failed)) }
        runtime.showSettings = { settingsWindow.show() }
        runtime.menuBar = MenuBarItem(
            onOpen: { [weak runtime] in runtime?.showPalette() },
            onSettings: { [weak runtime] in runtime?.showSettings() }, updater: updater)
        return runtime
    }
}

extension CommandID {
    /// Wicket Settings, a built-in in `live()`'s table, which ⌘, in the palette runs.
    static let settings = CommandID.builtin("settings")
    /// Loads the web images of the page its args name (`PaletteModel.loadImages`).
    static let loadImages = CommandID.builtin("load-images")
}
