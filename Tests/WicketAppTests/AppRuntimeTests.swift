import AppKit
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
    func show(eventTime: TimeInterval) {}
    func toggle(eventTime: TimeInterval) { toggles.append(eventTime) }
}

@MainActor
private final class FakeMenuBar: MenuBarSurface {
    private(set) var updates: [(visible: Bool, hotkey: Shortcut?)] = []
    func update(visible: Bool, hotkey: Shortcut?) { updates.append((visible, hotkey)) }
}

/// An agent that is always ready and answers "Hel…" without ever finishing, until its run is
/// cancelled (its process tree then takes `exitDelay` to exit) or `failure` is set (it fails with it).
private final class FakeAgent: Sendable {
    let started = Mutex(0)
    let ended = Mutex(0)
    let exitDelay = Mutex(Duration.zero)
    let failure = Mutex<String?>(nil)

    var backend: AgentBackend {
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) },
            run: { [self] _, _ in
                AgentRun { continuation in
                    self.started.withLock { $0 += 1 }
                    continuation.yield(.message("Hel"))
                    while !Task.isCancelled {
                        if let failure = self.failure.withLock({ $0 }) {
                            continuation.yield(.error(failure))
                            return .exited(.status(1))
                        }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    // Exiting takes its time, which cancellation doesn't cut short.
                    let delay = self.exitDelay.withLock { $0 }
                    await Task.detached { try? await Task.sleep(for: delay) }.value
                    self.ended.withLock { $0 += 1 }
                    return .terminated
                }
            })
    }
}

/// Waits up to 5 seconds of real time (agent runs are detached) for `condition`.
@MainActor
private func soon(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private let runAgentCommand = CommandID.builtin("run-agent")
private let quitCommand = CommandID.builtin("quit")

@MainActor
private final class Harness {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-runtime-\(UUID())")
    let system = FakeSystem()
    let palette = FakePalette()
    let menuBar = FakeMenuBar()
    let agent = FakeAgent()
    let runAgent: AgentRunner
    private(set) var work: [String] = []
    /// The built-ins' effects that ran.
    private(set) var effects: [String] = []
    let runtime: AppRuntime

    var session: PaletteSession { runtime.model.session }
    var store: SettingsStore { runtime.store }

    init(settings json: String = "{}") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        weak var harness: Harness?
        runAgent = AgentRunner(backend: agent.backend, provider: { harness?.runtime.applied?.ai.provider })
        // The table as `live()` composes it, with effects that are only recorded.
        let builtins = [
            Builtin(
                RegisteredCommand(
                    id: .settings, title: "Wicket Settings", icon: .symbol(name: "gearshape"), input: .none),
                effect: { harness?.effects.append("settings") }),
            Builtin(
                RegisteredCommand(
                    id: quitCommand, title: "Quit Wicket", icon: .symbol(name: "power"), input: .none),
                effect: { harness?.effects.append("quit") }),
            Builtin(
                RegisteredCommand(
                    id: runAgentCommand, title: "Run Agent", icon: .symbol(name: "sparkles"), keyword: "ai",
                    isListed: false, input: .submitText, placeholder: "Ask a question", isFallback: true,
                    usesAI: true),
                runner: runAgent),
        ]
        let apps = StaticSource("apps", items: [item("Safari")])
        let calculator = StaticSource("calculator", items: [])
        let diagnostics = Diagnostics()
        runtime = AppRuntime(
            store: SettingsStore(directory: directory, diagnostics: diagnostics),
            sources: [apps, calculator],
            work: [{ harness?.work.append("start apps") }, { harness?.work.append("start calculator") }],
            builtins: builtins,
            extensions: Extensions(
                directory: directory.appending(path: "extensions"),
                store: RevisionStore(root: directory.appending(path: "revisions")),
                approvals: Approvals(url: directory.appending(path: "approvals.json")),
                diagnostics: diagnostics
            ) { [directory] id in
                RunConfiguration(dataDirectory: directory.appending(path: "data/\(id)"), version: "test") {
                    _ in nil
                }
            },
            usageURL: directory.appending(path: "usage.json"), system: system.system)
        runtime.palette = palette
        runtime.menuBar = menuBar
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

    /// Why the palette's hotkey isn't in effect, as the General pane shows it.
    var hotkeyProblem: String? { store.diagnostics.text(for: .hotkey, kind: .hotkey) }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func shortcut(_ spelling: String) -> Shortcut { try! Shortcut(spelling) }

/// A `commands` object older builds wrote (per-command hotkeys and aliases) and their feature
/// switches other than AI bind and turn off nothing and, like any unknown key, warn about nothing.
@MainActor @Test func startingAppliesEverySetting() throws {
    let h = try Harness(
        settings: #"""
            {"hotkey": "cmd+k", "paletteWidth": 720, "ai": {"provider": "claude"},
             "features": {"calculator": false},
             "commands": {"builtin:run-agent": {"hotkey": "ctrl+option+a", "alias": "ask"}}}
            """#)
    #expect(h.palette.width == 720)
    #expect(h.runAgent.provider() == .claude)
    #expect(h.work == ["start apps", "start calculator"])
    #expect(h.system.registered == [shortcut("cmd+k")])
    #expect(h.store.diagnostics.all.isEmpty)

    h.system.press(shortcut("cmd+k"))
    #expect(h.palette.toggles == [42])
}

@MainActor @Test func theSourcesWorkStartsOnce() throws {
    let h = try Harness()
    #expect(h.work == ["start apps", "start calculator"])
    try h.change(#"{"paletteWidth": 540}"#)
    #expect(h.work.count == 2)
}

/// Settings and Quit are table entries like Run Agent: their rows run through the router, their effect
/// runs and the palette closes without a frame.
@MainActor @Test func builtinsThatDoSomethingRunTheirEffectAndClose() async throws {
    let h = try Harness()
    var closed = 0
    h.session.onClose = { closed += 1 }
    for id in [CommandID.settings, quitCommand] {
        h.session.open(CommandRun(try #require(h.runtime.registry.command(id)), .invoked))
    }
    #expect(await eventually { closed == 1 })
    // Opening Quit cancelled Settings' opening before it ran: one at a time, like any command.
    #expect(h.effects == ["quit"])
    h.session.open(CommandRun(try #require(h.runtime.registry.command(.settings)), .invoked))
    #expect(await eventually { closed == 2 })
    #expect(h.effects == ["quit", "settings"])
    #expect(h.session.frames.count == 1)
}

@MainActor @Test func turningAIOffTakesItsRowsAtOnce() throws {
    let h = try Harness()
    h.session.query = "saf"
    #expect(h.rootIDs.contains("fallback:builtin:run-agent"))
    try h.change(#"{"ai": {"enabled": false}}"#)
    #expect(h.rootIDs.contains("test:Safari"))
    #expect(!h.rootIDs.contains("fallback:builtin:run-agent"))
}

/// The review's gap: turning Run Agent off left a running answer streaming.
@MainActor @Test func turningRunAgentOffStopsARunningAnswer() async throws {
    let h = try Harness()
    let command = try #require(h.runtime.registry.command(runAgentCommand))
    h.session.open(CommandRun(command, .invoked, text: "hello"))
    #expect(await eventually { h.session.frames.count == 2 })
    #expect(h.session.top.isLoading)

    try h.change(#"{"ai": {"enabled": false}}"#)
    #expect(h.session.frames.count == 1)
    #expect(await eventually { h.agent.ended.withLock { $0 } == 1 })
}

/// Quitting waits for what runs outside the app: the answer's agent is gone when `shutdown` returns.
@MainActor @Test func shutdownWaitsForRunningAgentsOnce() async throws {
    let h = try Harness()
    h.agent.exitDelay.withLock { $0 = .milliseconds(200) }
    let command = try #require(h.runtime.registry.command(runAgentCommand))
    h.session.open(CommandRun(command, .invoked, text: "hello"))
    #expect(await soon { h.agent.started.withLock { $0 } == 1 })

    await h.runtime.shutdown()
    #expect(h.agent.ended.withLock { $0 } == 1)
    #expect(h.session.frames.count == 1)

    // Once only, and nothing starts after it.
    let start = ContinuousClock.now
    await h.runtime.shutdown()
    #expect(ContinuousClock.now - start < .milliseconds(100))
    h.session.open(CommandRun(command, .invoked, text: "again"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(h.agent.started.withLock { $0 } == 1)
    #expect(h.agent.ended.withLock { $0 } == 1)
}

/// A process that won't die doesn't keep the app from quitting.
@MainActor @Test func shutdownIsBounded() async throws {
    let h = try Harness()
    h.agent.exitDelay.withLock { $0 = .seconds(30) }
    let command = try #require(h.runtime.registry.command(runAgentCommand))
    h.session.open(CommandRun(command, .invoked, text: "hello"))
    #expect(await soon { h.agent.started.withLock { $0 } == 1 })

    let start = ContinuousClock.now
    await h.runtime.shutdown(within: .milliseconds(300))
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(h.agent.ended.withLock { $0 } == 0)
}

/// The review's gap: a bad main hotkey made the whole file invalid. Now it is ignored on its own and
/// the default summons Wicket.
@MainActor @Test func aBadHotkeyCostsOnlyItself() throws {
    let h = try Harness(settings: #"{"hotkey": "shift+k", "paletteWidth": 720}"#)
    #expect(h.store.loadError == nil)
    #expect(h.store.settings.ignored.count == 1)
    #expect(h.system.registered == [.default])
    #expect(h.palette.width == 720)
}

/// The review's gap: the palette let go of its hotkey before knowing the new one would register, so
/// a combination another app holds left Wicket unsummonable. It keeps the one it had, and says so.
@MainActor @Test func aTakenPaletteHotkeyKeepsTheOldOne() throws {
    let h = try Harness()
    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.change(#"{"hotkey": "cmd+k"}"#)
    #expect(h.system.registered == [.default])
    #expect(h.hotkeyProblem == "⌘K is in use by another app. \(Shortcut.default.symbols) still opens Wicket.")
    h.system.press(.default)
    #expect(h.palette.toggles == [42])

    // Freed, it is taken on the next apply.
    h.system.heldElsewhere = []
    try h.change(#"{"hotkey": "cmd+k", "paletteWidth": 720}"#)
    #expect(h.system.registered == [shortcut("cmd+k")])
    #expect(h.hotkeyProblem == nil)
}

/// The same through the recorder, which releases the hotkey while it listens.
@MainActor @Test func aRecordedHotkeyAnotherAppHoldsKeepsTheOldOne() throws {
    let h = try Harness()
    h.store.pauseHotKey(true)
    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.write(#"{"hotkey": "cmd+k"}"#)
    h.store.pauseHotKey(false)
    #expect(h.system.registered == [.default])
    #expect(h.hotkeyProblem != nil)
}

@MainActor @Test func recordingAHotkeyReleasesIt() throws {
    let h = try Harness()
    h.store.pauseHotKey(true)
    #expect(h.system.registered.isEmpty)
    #expect(h.hotkeyProblem == nil)
    // The recorder writes the new hotkey, then ends; it is registered at once.
    try h.write(#"{"hotkey": "cmd+k"}"#)
    h.store.pauseHotKey(false)
    #expect(h.system.registered == [shortcut("cmd+k")])
}

/// One message channel: the session's command messages and the paste effect's (given
/// `runtime.messages` in `live()`) both reach the one presenter.
@MainActor @Test func messagesHaveOneChannel() throws {
    let h = try Harness()
    #expect(h.session.messages === h.runtime.messages)
    var shown: [Message] = []
    h.runtime.messages.present = { shown.append($0) }
    h.runtime.messages.post(Message("Copied, not pasted", kind: .copied))
    #expect(shown == [Message("Copied, not pasted", kind: .copied)])
}

/// settings.json's ignored fields and a file that can't be read are diagnostics; the panes read
/// them there.
@MainActor @Test func settingsProblemsAreDiagnostics() throws {
    let h = try Harness(settings: #"{"paletteWidth": 5}"#)
    #expect(
        h.store.diagnostics.text(for: .settings, kind: .settings)
            == "paletteWidth must be a number from 480 to 900; using 600")
    #expect(h.store.loadError == nil)
    try h.change("{")
    #expect(h.store.loadError != nil)
    #expect(h.store.diagnostics.entries(for: .settings).map(\.severity) == [.error])
    try h.change("{}")
    #expect(h.store.diagnostics.all.isEmpty)
}

// MARK: Extensions and consent

/// Writes an extension `hello` with one once command (keyword `hello`) that answers "Hi", into the harness's extensions folder, and discovers it.
@MainActor
private func addHello(_ h: Harness) async throws {
    let folder = h.directory.appending(path: "extensions/hello")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(
        #"""
        {"protocol":2,"id":"hello","name":"Hello","version":"1.0.0","run":["/bin/sh","main.sh"],
         "commands":[{"id":"go","title":"Say Hello","keyword":"hello"}]}
        """#.utf8
    ).write(to: folder.appending(path: "wicket.json"))
    try Data(
        #"""
        cat >/dev/null
        printf '{"answer":{"title":"Hi"}}\n'
        """#.utf8
    ).write(to: folder.appending(path: "main.sh"))
    await h.runtime.extensions.load(changed: [folder.path]).value
}

@MainActor @Test func settingsJSONCanGrantNothing() async throws {
    // Keys that look like consent.
    let h = try Harness(
        settings: #"{"extensions": {"hello": {"enabled": true}}, "approvals": {"hello": "any"}}"#)
    try await addHello(h)
    let hello = CommandID.extension("hello", "go")
    #expect(h.runtime.extensions.discovered.map(\.id) == ["hello"])
    #expect(h.runtime.registry.command(hello) == nil)
    h.session.query = "Say Hello"
    #expect(!h.rootIDs.contains { $0.hasPrefix("ext:") || $0.contains("hello/go") })
    #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: "approvals.json").path))
    #expect(h.runtime.extensions.approvals.all.isEmpty)
}

@MainActor @Test func approvingAndRevokingAnExtensionUpdatesThePalette() async throws {
    let h = try Harness()
    try await addHello(h)
    let hello = CommandID.extension("hello", "go")
    let sealed = try #require(h.runtime.extensions.discovered.first?.sealed)

    // Approved, its command is registered and it runs.
    try await h.runtime.extensions.approve(sealed.revision)
    let command = try #require(h.runtime.registry.command(hello))
    #expect(command.revision == sealed.revision)
    h.session.open(CommandRun(command, .invoked))
    #expect(await soon { h.session.frames.count == 2 && h.session.top.list?.items.first?.title == "Hi" })

    // Revoked, it leaves the registry and its frame stops.
    try await h.runtime.extensions.revoke("hello")
    #expect(h.runtime.registry.command(hello) == nil)
    #expect(h.session.frames.count == 1)
}

/// The icon follows settings.json live and shows the hotkey that opens Wicket, the previous one
/// while another app holds the new one.
@MainActor @Test func menuBarFollowsSettings() throws {
    let h = try Harness()
    #expect(h.menuBar.updates.last?.visible == true)
    #expect(h.menuBar.updates.last?.hotkey == .default)
    try h.change(#"{"showInMenuBar": false, "hotkey": "cmd+k"}"#)
    #expect(h.menuBar.updates.last?.visible == false)
    #expect(h.menuBar.updates.last?.hotkey == shortcut("cmd+k"))
    h.system.heldElsewhere = [shortcut("ctrl+k")]
    try h.change(#"{"hotkey": "ctrl+k"}"#)
    #expect(h.menuBar.updates.last?.visible == true)
    #expect(h.menuBar.updates.last?.hotkey == shortcut("cmd+k"))
}

/// Pages take the text size from settings.json live.
@MainActor @Test func textSizeFollowsSettings() throws {
    let h = try Harness()
    #expect(h.runtime.model.textSize == .medium)
    try h.change(#"{"textSize": "larger"}"#)
    #expect(h.runtime.model.textSize == .larger)
    try h.change(#"{}"#)
    #expect(h.runtime.model.textSize == .medium)
}

/// The menu shows the hotkey as a key equivalent: the key as AppKit spells it, Carbon's modifiers
/// as AppKit's.
@Test func shortcutAsMenuKeyEquivalent() throws {
    let cases: [(String, String, NSEvent.ModifierFlags)] = [
        ("option+space", " ", .option),
        ("ctrl+shift+k", "k", [.control, .shift]),
        ("cmd+return", "\r", .command),
        ("f13", String(Character(Unicode.Scalar(NSF13FunctionKey)!)), []),
    ]
    for (spelling, key, flags) in cases {
        let hotkey = try Shortcut(spelling)
        #expect(hotkey.keyEquivalent == key, "\(spelling)")
        #expect(hotkey.modifierFlags == flags, "\(spelling)")
    }
}
