import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketApp
@testable import WicketHost

// The runtime applying settings.json: one snapshot at a time, coherently, through fakes for the
// system (no real hotkey is registered, no folder watched, no app scanned, no agent run).

/// Stands in for Carbon and FSEvents. Like Carbon it refuses a combination that is already held, by
/// this app or (`heldElsewhere`) another.
@MainActor
private final class FakeSystem {
    var heldElsewhere: Set<Shortcut> = []
    private var handlers: [Shortcut: (id: Int, handler: HotKey.Handler)] = [:]
    private var lastID = 0
    /// The folders watched, each with what to call when it changes.
    private(set) var watchers: [(paths: [String], onChange: @MainActor ([String]) -> Void)] = []

    var registered: Set<Shortcut> { Set(handlers.keys) }

    var system: AppRuntime.System {
        AppRuntime.System(
            registerHotKey: { [unowned self] shortcut, handler in
                guard handlers[shortcut] == nil, !heldElsewhere.contains(shortcut) else { return nil }
                lastID += 1
                let id = lastID
                handlers[shortcut] = (id, handler)
                return Registration { [weak self] in
                    if self?.handlers[shortcut]?.id == id { self?.handlers[shortcut] = nil }
                }
            },
            watch: { [unowned self] paths, _, onChange in
                watchers.append((paths, onChange))
                return Registration {}
            })
    }

    func press(_ shortcut: Shortcut) {
        handlers[shortcut]?.handler(42)
    }

    /// What FSEvents does when settings.json changes.
    func settingsChanged() {
        for watcher in watchers where watcher.paths.contains(where: { !$0.hasSuffix("extensions") }) {
            watcher.onChange(watcher.paths)
        }
    }
}

/// Released, it unregisters (like `HotKey`) or stops watching.
@MainActor
private final class Registration {
    let onRelease: @MainActor () -> Void
    init(_ onRelease: @escaping @MainActor () -> Void) { self.onRelease = onRelease }
    isolated deinit { onRelease() }
}

@MainActor
private final class FakePalette: PaletteSurface {
    var width: CGFloat = 0
    private(set) var toggles: [TimeInterval] = []
    private(set) var bound: [CommandID] = []
    func show(eventTime: TimeInterval) {}
    func toggle(eventTime: TimeInterval) { toggles.append(eventTime) }
    func run(bound id: CommandID) { bound.append(id) }
}

/// An agent that is always ready and answers "Hel…" without ever finishing, until its run ends.
private final class FakeAgent: Sendable {
    let ended = Mutex(0)

    var backend: AgentBackend {
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) },
            run: { [self] _, _ in
                AsyncStream { continuation in
                    continuation.onTermination = { _ in self.ended.withLock { $0 += 1 } }
                    continuation.yield(.text("Hel"))
                }
            })
    }
}

@MainActor
private final class Harness {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-runtime-\(UUID())")
    let system = FakeSystem()
    let palette = FakePalette()
    let agent = FakeAgent()
    let askAI: AskAIRunner
    private(set) var work: [String] = []
    let runtime: AppRuntime

    var session: PaletteSession { runtime.model.session }
    var store: SettingsStore { runtime.store }

    init(settings json: String = "{}") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        askAI = AskAIRunner(backend: agent.backend, interval: .zero)
        let apps = StaticSource("apps", items: [item("Safari")])
        let calculator = StaticSource("calculator", items: [])
        weak var harness: Harness?
        let work = { (feature: Feature) in
            AppRuntime.Work(
                start: { harness?.work.append("start \(feature.rawValue)") },
                stop: { harness?.work.append("stop \(feature.rawValue)") })
        }
        runtime = AppRuntime(
            store: SettingsStore(directory: directory), sources: [apps, calculator],
            work: [.apps: work(.apps), .calculator: work(.calculator)], askAI: askAI,
            extensions: Extensions(directory: directory.appending(path: "extensions")),
            usageURL: directory.appending(path: "usage.json"), system: system.system)
        runtime.palette = palette
        harness = self
        try write(json)
        runtime.start()
    }

    /// Writes settings.json and lets the runtime see it, as FSEvents would.
    func write(_ json: String) throws {
        try Data(json.utf8).write(to: store.url)
    }

    func change(_ json: String) throws {
        try write(json)
        system.settingsChanged()
    }

    var rootIDs: [String] { session.frames[0].list?.items.map(\.id) ?? [] }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func shortcut(_ spelling: String) -> Shortcut { try! Shortcut(spelling) }

@MainActor @Test func startingAppliesEverySetting() throws {
    let h = try Harness(
        settings: #"""
            {"hotkey": "cmd+k", "paletteWidth": 720, "ai": {"provider": "claude"},
             "features": {"calculator": false},
             "commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a", "alias": "ask"}}}
            """#)
    #expect(h.palette.width == 720)
    #expect(h.askAI.provider == .claude)
    #expect(h.work == ["start apps"])
    #expect(h.system.registered == [shortcut("cmd+k"), shortcut("ctrl+option+a")])
    #expect(h.runtime.registry.alias(of: AskAI.command) == "ask")
    #expect(h.store.commands.map(\.id) == h.runtime.registry.commands.map(\.id))
    #expect(h.store.bindingProblems.isEmpty)

    h.system.press(shortcut("cmd+k"))
    h.system.press(shortcut("ctrl+option+a"))
    #expect(h.palette.toggles == [42])
    #expect(h.palette.bound == [AskAI.command])
}

@MainActor @Test func featureWorkFollowsItsFeatureOnly() throws {
    let h = try Harness()
    #expect(h.work == ["start apps", "start calculator"])
    try h.change(#"{"paletteWidth": 540}"#)
    #expect(h.work.count == 2)  // Nothing restarts for an unrelated change.
    try h.change(#"{"features": {"apps": false}}"#)
    #expect(h.work == ["start apps", "start calculator", "stop apps"])
    try h.change("{}")
    #expect(h.work.last == "start apps")
}

/// The review's gap: a new alias didn't reach the results already on screen.
@MainActor @Test func anAliasChangeRefreshesTheResultsOnScreen() throws {
    let h = try Harness()
    h.session.query = "bye"
    #expect(!h.rootIDs.contains("commands:quit"))

    try h.change(#"{"commands": {"builtin:quit": {"alias": "bye"}}}"#)
    #expect(h.rootIDs.first == "commands:quit")
    #expect(h.session.frames[0].list?.items.first?.relevance == .alias)

    try h.change("{}")
    #expect(!h.rootIDs.contains("commands:quit"))
}

@MainActor @Test func turningAFeatureOffTakesItsRowsAtOnce() throws {
    let h = try Harness()
    h.session.query = "saf"
    #expect(h.rootIDs.contains("test:Safari"))
    #expect(h.rootIDs.contains("fallback:builtin:ask-ai"))
    try h.change(#"{"features": {"apps": false, "ask-ai": false}}"#)
    #expect(!h.rootIDs.contains("test:Safari"))
    #expect(!h.rootIDs.contains("fallback:builtin:ask-ai"))
}

/// The review's gap: turning Ask AI off left a running answer streaming.
@MainActor @Test func turningAskAIOffStopsARunningAnswer() async throws {
    let h = try Harness(settings: #"{"commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a"}}}"#)
    let command = try #require(h.runtime.registry.command(AskAI.command))
    h.session.open(CommandRun(command, .invoked, text: "hello"))
    #expect(await eventually { h.session.frames.count == 2 })
    #expect(h.session.top.isLoading)

    try h.change(
        #"{"features": {"ask-ai": false}, "commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a"}}}"#)
    #expect(h.session.frames.count == 1)
    #expect(await eventually { h.agent.ended.withLock { $0 } == 1 })
    // Its hotkey goes inert with it, and comes back when the feature does.
    #expect(h.system.registered == [.default])
    try h.change(#"{"commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a"}}}"#)
    #expect(h.system.registered == [.default, shortcut("ctrl+option+a")])
}

/// One snapshot can hand a combination from a command to the palette and back.
@MainActor @Test func hotkeysCanSwapInOneChange() throws {
    let h = try Harness(settings: #"{"commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a"}}}"#)
    try h.change(#"{"hotkey": "ctrl+option+a", "commands": {"builtin:ask-ai": {"hotkey": "option+space"}}}"#)
    #expect(h.system.registered == [shortcut("ctrl+option+a"), .default])
    h.system.press(shortcut("ctrl+option+a"))
    h.system.press(.default)
    #expect(h.palette.toggles == [42])
    #expect(h.palette.bound == [AskAI.command])
    #expect(!h.store.hotKeyFailed)
}

/// The review's gap: a bad main hotkey made the whole file invalid, while a bad binding cost only
/// itself. Now it is ignored on its own and the default summons Wicket.
@MainActor @Test func aBadHotkeyCostsOnlyItself() throws {
    let h = try Harness(settings: #"{"hotkey": "shift+k", "commands": {"builtin:quit": {"alias": "bye"}}}"#)
    #expect(h.store.loadError == nil)
    #expect(h.store.settings.ignored.count == 1)
    #expect(h.system.registered == [.default])
    #expect(h.runtime.registry.alias(of: BuiltinCommand.quit.id) == "bye")
}

@MainActor @Test func aHotkeyAnotherAppHoldsIsRetried() throws {
    let h = try Harness()
    h.system.heldElsewhere = [.default, shortcut("ctrl+option+a")]
    try h.change(#"{"commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    // The palette keeps the default it holds; Quit's is in use elsewhere.
    #expect(h.system.registered == [.default])
    #expect(h.store.bindingProblems[BuiltinCommand.quit.id] == "⌃⌥A is in use by another app.")

    try h.change(#"{"hotkey": "cmd+k", "commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    h.system.heldElsewhere = []
    try h.change(#"{"hotkey": "option+space", "commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    #expect(h.system.registered == [.default, shortcut("ctrl+option+a")])
    #expect(h.store.bindingProblems.isEmpty)
    #expect(!h.store.hotKeyFailed)

    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.change(#"{"hotkey": "cmd+k"}"#)
    #expect(h.store.hotKeyFailed)
}

@MainActor @Test func recordingAHotkeyPausesEveryHotkey() throws {
    let h = try Harness(settings: #"{"commands": {"builtin:quit": {"hotkey": "ctrl+option+q"}}}"#)
    h.store.pauseHotKey(true)
    #expect(h.system.registered.isEmpty)
    #expect(!h.store.hotKeyFailed)
    // The recorder writes the new hotkey, then ends; it is registered at once.
    try h.write(#"{"hotkey": "cmd+k", "commands": {"builtin:quit": {"hotkey": "ctrl+option+q"}}}"#)
    h.store.pauseHotKey(false)
    #expect(h.system.registered == [shortcut("cmd+k"), shortcut("ctrl+option+q")])
}
