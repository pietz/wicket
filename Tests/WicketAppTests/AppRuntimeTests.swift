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
    private(set) var bound: [CommandID] = []
    func show(eventTime: TimeInterval) {}
    func toggle(eventTime: TimeInterval) { toggles.append(eventTime) }
    func run(bound id: CommandID) { bound.append(id) }
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
                    continuation.yield(.text("Hel"))
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

private let askAICommand = CommandID.builtin("ask-ai")
private let quitCommand = CommandID.builtin("quit")

@MainActor
private final class Harness {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-runtime-\(UUID())")
    let system = FakeSystem()
    let palette = FakePalette()
    let menuBar = FakeMenuBar()
    let agent = FakeAgent()
    let askAI: AskAIRunner
    let buildJobs: BuildJobs
    private(set) var work: [String] = []
    /// The built-ins' effects that ran.
    private(set) var effects: [String] = []
    let runtime: AppRuntime

    var session: PaletteSession { runtime.model.session }
    var store: SettingsStore { runtime.store }

    init(settings json: String = "{}") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        weak var harness: Harness?
        askAI = AskAIRunner(
            backend: agent.backend, interval: .zero, provider: { harness?.runtime.applied?.ai.provider })
        buildJobs = BuildJobs(
            backend: agent.backend, staging: directory.appending(path: "staging"), guide: { "guide" })
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
                    id: askAICommand, title: "Ask AI", icon: .symbol(name: "sparkles"), keyword: "ai",
                    isListed: false, input: .submitText, placeholder: "Ask a question", isFallback: true,
                    feature: .askAI),
                runner: askAI),
            Builtin(
                RegisteredCommand(
                    id: .makeCommand, title: "Make a Command", icon: .symbol(name: "hammer"), keyword: "make",
                    input: .submitText, placeholder: "Describe the command to make"),
                runner: MakeCommandRunner(jobs: buildJobs)),
        ]
        let apps = StaticSource("apps", items: [item("Safari")])
        let calculator = StaticSource("calculator", items: [])
        let work = { (feature: Feature) in
            AppRuntime.Work(
                start: { harness?.work.append("start \(feature.rawValue)") },
                stop: { harness?.work.append("stop \(feature.rawValue)") })
        }
        let diagnostics = Diagnostics()
        runtime = AppRuntime(
            store: SettingsStore(directory: directory, diagnostics: diagnostics),
            sources: [apps, calculator],
            work: [.apps: work(.apps), .calculator: work(.calculator)], builtins: builtins,
            extensions: Extensions(
                directory: directory.appending(path: "extensions"),
                store: RevisionStore(root: directory.appending(path: "revisions")),
                approvals: Approvals(url: directory.appending(path: "approvals.json")),
                diagnostics: diagnostics
            ) { [directory] id in
                SessionConfiguration(dataDirectory: directory.appending(path: "data/\(id)"), version: "test")
                { _ in nil }
            },
            buildJobs: buildJobs, usageURL: directory.appending(path: "usage.json"), system: system.system)
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
    #expect(h.askAI.provider() == .claude)
    #expect(h.work == ["start apps"])
    #expect(h.system.registered == [shortcut("cmd+k"), shortcut("ctrl+option+a")])
    #expect(h.runtime.registry.alias(of: askAICommand) == "ask")
    #expect(h.store.commands.map(\.id) == h.runtime.registry.commands.map(\.id))
    #expect(h.store.diagnostics.all.isEmpty)

    h.system.press(shortcut("cmd+k"))
    h.system.press(shortcut("ctrl+option+a"))
    #expect(h.palette.toggles == [42])
    #expect(h.palette.bound == [askAICommand])
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

/// Settings and Quit are table entries like Ask AI: their rows run through the router, their effect
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
    let command = try #require(h.runtime.registry.command(askAICommand))
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

/// Quitting waits for what runs outside the app: the answer's agent is gone when `shutdown` returns.
@MainActor @Test func shutdownWaitsForRunningAgentsOnce() async throws {
    let h = try Harness()
    h.agent.exitDelay.withLock { $0 = .milliseconds(200) }
    let command = try #require(h.runtime.registry.command(askAICommand))
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

/// Quitting cancels a running build job, which outlives its frame, and waits for its agent.
@MainActor @Test func shutdownCancelsARunningBuildJob() async throws {
    let h = try Harness()
    h.agent.exitDelay.withLock { $0 = .milliseconds(200) }
    let command = try #require(h.runtime.registry.command(.makeCommand))
    h.session.open(CommandRun(command, .invoked, text: "show the week number"))
    #expect(await soon { h.agent.started.withLock { $0 } == 1 })
    h.session.reset()  // Detached: the job keeps running.
    let job = try #require(h.buildJobs.current)
    #expect(job.phase.isRunning)

    await h.runtime.shutdown()
    #expect(h.agent.ended.withLock { $0 } == 1)
    guard case .cancelled = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
}

/// A process that won't die doesn't keep the app from quitting.
@MainActor @Test func shutdownIsBounded() async throws {
    let h = try Harness()
    h.agent.exitDelay.withLock { $0 = .seconds(30) }
    let command = try #require(h.runtime.registry.command(askAICommand))
    h.session.open(CommandRun(command, .invoked, text: "hello"))
    #expect(await soon { h.agent.started.withLock { $0 } == 1 })

    let start = ContinuousClock.now
    await h.runtime.shutdown(within: .milliseconds(300))
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(h.agent.ended.withLock { $0 } == 0)
}

/// One snapshot can hand a combination from a command to the palette and back.
@MainActor @Test func hotkeysCanSwapInOneChange() throws {
    let h = try Harness(settings: #"{"commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a"}}}"#)
    try h.change(#"{"hotkey": "ctrl+option+a", "commands": {"builtin:ask-ai": {"hotkey": "option+space"}}}"#)
    #expect(h.system.registered == [shortcut("ctrl+option+a"), .default])
    h.system.press(shortcut("ctrl+option+a"))
    h.system.press(.default)
    #expect(h.palette.toggles == [42])
    #expect(h.palette.bound == [askAICommand])
    #expect(!h.store.hotKeyFailed)
}

/// The review's gap: a bad main hotkey made the whole file invalid, while a bad binding cost only
/// itself. Now it is ignored on its own and the default summons Wicket.
@MainActor @Test func aBadHotkeyCostsOnlyItself() throws {
    let h = try Harness(settings: #"{"hotkey": "shift+k", "commands": {"builtin:quit": {"alias": "bye"}}}"#)
    #expect(h.store.loadError == nil)
    #expect(h.store.settings.ignored.count == 1)
    #expect(h.system.registered == [.default])
    #expect(h.runtime.registry.alias(of: quitCommand) == "bye")
}

@MainActor @Test func aHotkeyAnotherAppHoldsIsRetried() throws {
    let h = try Harness()
    h.system.heldElsewhere = [.default, shortcut("ctrl+option+a")]
    try h.change(#"{"commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    // The palette keeps the default it holds; Quit's is in use elsewhere.
    #expect(h.system.registered == [.default])
    #expect(
        h.store.diagnostics.text(for: .command(quitCommand), kind: .binding)
            == "⌃⌥A is in use by another app.")

    try h.change(#"{"hotkey": "cmd+k", "commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    h.system.heldElsewhere = []
    try h.change(#"{"hotkey": "option+space", "commands": {"builtin:quit": {"hotkey": "ctrl+option+a"}}}"#)
    #expect(h.system.registered == [.default, shortcut("ctrl+option+a")])
    #expect(h.store.diagnostics.all.isEmpty)
    #expect(!h.store.hotKeyFailed)

    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.change(#"{"hotkey": "cmd+k"}"#)
    #expect(h.store.hotKeyFailed)
}

/// The review's gap: the palette let go of its hotkey before knowing the new one would register, so
/// a combination another app holds left Wicket unsummonable. It keeps the one it had, and says so.
@MainActor @Test func aTakenPaletteHotkeyKeepsTheOldOne() throws {
    let h = try Harness()
    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.change(#"{"hotkey": "cmd+k"}"#)
    #expect(h.system.registered == [.default])
    #expect(
        h.store.diagnostics.text(for: .bindings, kind: .binding)
            == "⌘K is in use by another app. \(Shortcut.default.symbols) still opens Wicket.")
    h.system.press(.default)
    #expect(h.palette.toggles == [42])

    // Freed, it is taken on the next apply.
    h.system.heldElsewhere = []
    try h.change(#"{"hotkey": "cmd+k", "paletteWidth": 720}"#)
    #expect(h.system.registered == [shortcut("cmd+k")])
    #expect(!h.store.hotKeyFailed)
}

/// The same through the recorder, which pauses every hotkey while it listens.
@MainActor @Test func aRecordedHotkeyAnotherAppHoldsKeepsTheOldOne() throws {
    let h = try Harness()
    h.store.pauseHotKey(true)
    h.system.heldElsewhere = [shortcut("cmd+k")]
    try h.write(#"{"hotkey": "cmd+k"}"#)
    h.store.pauseHotKey(false)
    #expect(h.system.registered == [.default])
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

/// A build that ends while its frame isn't on screen (the palette closed, another command on top)
/// tells the user through the message channel; one whose frame is showing doesn't.
@MainActor @Test func aBuildEndingUnwatchedPostsAMessage() async throws {
    let h = try Harness()
    var shown: [Message] = []
    h.runtime.messages.present = { shown.append($0) }
    let command = try #require(h.runtime.registry.command(.makeCommand))

    // Watched: the build frame is on top when it fails.
    h.session.open(CommandRun(command, .invoked, text: "show the week number"))
    #expect(
        await soon {
            if case .screen(let frame) = h.session.top.content {
                frame.run?.command.id == .makeCommand
            } else {
                false
            }
        })
    let watched = try #require(h.buildJobs.current)
    h.agent.failure.withLock { $0 = "rate limited" }
    await watched.finished()
    #expect(shown.isEmpty)

    // Unwatched: the palette was closed.
    h.agent.failure.withLock { $0 = nil }
    h.session.reset()
    let unwatched = try h.buildJobs.start("count my tabs")
    #expect(await soon { h.agent.started.withLock { $0 } == 2 })
    h.agent.failure.withLock { $0 = "rate limited" }
    await unwatched.finished()
    #expect(shown == [Message("Making the command failed: open Extensions to see why.", kind: .failed)])
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

/// Writes an extension `hello` with one once command (keyword `hello`) that answers "Hi" and keeps
/// running, into the harness's extensions folder, and discovers it.
@MainActor
private func addHello(_ h: Harness) async throws {
    let folder = h.directory.appending(path: "extensions/hello")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(
        #"""
        {"protocol":1,"id":"hello","name":"Hello","version":"1.0.0","run":["/bin/sh","main.sh"],
         "commands":[{"id":"go","title":"Say Hello","keyword":"hello"}]}
        """#.utf8
    ).write(to: folder.appending(path: "wicket.json"))
    try Data(
        #"""
        while read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"answer":{"title":"Hi"}}}\n' "$id"
        done
        """#.utf8
    ).write(to: folder.appending(path: "main.sh"))
    await h.runtime.extensions.load(changed: [folder.path]).value
}

@MainActor @Test func settingsJSONCanGrantNothing() async throws {
    // Everything settings.json could try: a binding, an alias, and keys that look like consent.
    let h = try Harness(
        settings: #"""
            {"commands": {"ext:hello/go": {"hotkey": "ctrl+option+h", "alias": "hey"}},
             "extensions": {"hello": {"enabled": true}}, "approvals": {"hello": "any"}}
            """#)
    try await addHello(h)
    let hello = CommandID.extension("hello", "go")
    #expect(h.runtime.extensions.discovered.map(\.id) == ["hello"])
    #expect(h.runtime.registry.command(hello) == nil)
    #expect(!h.system.registered.contains(shortcut("ctrl+option+h")))
    h.session.query = "Say Hello"
    #expect(!h.rootIDs.contains { $0.hasPrefix("ext:") || $0.contains("hello/go") })
    #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: "approvals.json").path))
    #expect(h.runtime.extensions.approvals.all.isEmpty)
}

@MainActor @Test func approvingAndRevokingAnExtensionUpdatesThePalette() async throws {
    let h = try Harness(settings: #"{"commands": {"ext:hello/go": {"hotkey": "ctrl+option+h"}}}"#)
    try await addHello(h)
    let hello = CommandID.extension("hello", "go")
    let sealed = try #require(h.runtime.extensions.discovered.first?.sealed)

    // Approved, its command is registered, its waiting binding takes effect, and it runs.
    try await h.runtime.extensions.approve(sealed.revision)
    let command = try #require(h.runtime.registry.command(hello))
    #expect(command.revision == sealed.revision)
    #expect(h.system.registered.contains(shortcut("ctrl+option+h")))
    h.session.open(CommandRun(command, .invoked))
    #expect(await soon { h.session.frames.count == 2 && h.session.top.list?.items.first?.title == "Hi" })

    // Revoked, it leaves the registry, its frame stops and its hotkey is released.
    try await h.runtime.extensions.revoke("hello")
    #expect(h.runtime.registry.command(hello) == nil)
    #expect(h.session.frames.count == 1)
    #expect(!h.system.registered.contains(shortcut("ctrl+option+h")))
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
