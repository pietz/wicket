import Foundation
import Testing

@testable import WicketCore

/// Records every effect.
@MainActor
private final class FakeEffects: ActionEffects {
    enum Call: Equatable {
        case open(URL)
        case copy(String)
        case paste(String, RunningApp?)
        case reveal(URL)
    }

    var calls: [Call] = []
    /// What `inspect` finds, by path; anything else isn't there.
    var files: [String: LinkedFile] = [:]

    func open(_ url: URL) { calls.append(.open(url)) }
    func copy(_ text: String) { calls.append(.copy(text)) }
    func paste(_ text: String, into app: RunningApp?) { calls.append(.paste(text, app)) }
    func reveal(_ url: URL) { calls.append(.reveal(url)) }
    func inspect(_ file: URL) -> LinkedFile? { files[file.path(percentEncoded: false)] }
}

private let todoAdd = CommandID.extension("todo", "add")
private let todoDone = CommandID.extension("todo", "done")
private let addTodo = RegisteredCommand(id: todoAdd, title: "Add Todo", icon: .symbol(name: "plus"))
private let markDone = RegisteredCommand(
    id: todoDone, title: "Mark as Done", icon: .symbol(name: "checkmark"), isListed: false)

@MainActor
private func dispatcher(_ effects: FakeEffects) -> ActionDispatcher {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([addTodo, markDone])
    return ActionDispatcher(registry: registry, effects: effects)
}

private let file = URL(filePath: "/tmp/a.txt")
private let mail = RunningApp(processID: 42, bundleID: "com.apple.mail")

@MainActor
@Test func systemActionsCallTheirEffectAndClose() async {
    let effects = FakeEffects()
    effects.files = [file.path: LinkedFile(target: file, isRunnable: false)]
    let actions = dispatcher(effects)
    let context = ActionContext(previousApp: mail)
    for action in [Item.Action.open(url: file), .copy(text: "42"), .paste(text: "😸"), .reveal(url: file)] {
        #expect(actions.perform(action, as: .host, in: context) == .close)
    }
    #expect(effects.calls == [.open(file), .copy("42"), .paste("😸", mail), .reveal(file)])
}

@MainActor
@Test func aDetailIsPushedWithoutEffects() async {
    let effects = FakeEffects()
    let page = Detail(title: "Page", markdown: "# Page")
    #expect(dispatcher(effects).perform(.detail(page), as: .host, in: ActionContext()) == .push(page, .host))
    #expect(effects.calls.isEmpty)
}

/// A built-in that just does something is an ordinary command: the dispatcher opens it, and its
/// runner does the effect and closes the palette before any frame shows.
@MainActor
@Test func builtinsThatDoSomethingRunTheirEffectAndClose() async {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    let outcome = actions.perform(.run(command: CommandID.settings), as: .host, in: ActionContext())
    #expect(outcome == .open(CommandRun(.settings, .invoked)))
    #expect(effects.calls.isEmpty)

    var opened = 0
    let registry = CommandRegistry(builtins: builtins)
    let router = CommandRouter(
        builtins: [Builtin(.settings, effect: { opened += 1 })], extensions: nil)
    let session = PaletteSession(sources: [], runner: router, registry: registry)
    var closed = 0
    session.onClose = { closed += 1 }
    guard case .open(let run) = outcome else { return }
    session.open(run)
    #expect(await eventually { closed == 1 })
    #expect(opened == 1)
    #expect(session.frames.count == 1)
    #expect(session.opening == nil)
}

/// Lets the session's tasks run until `condition` holds, for up to two seconds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Test func extensionCommandsOpenTheirFrame() {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    // Through the invocation policy: a once command runs now, never resent whether listed or not,
    // with or without args.
    let add = actions.perform(.run(command: todoAdd), as: .host, in: ActionContext())
    #expect(add == .open(CommandRun(addTodo, .invoked)))
    #expect(
        add == .open(CommandRun(command: addTodo, invocation: Invocation(command: todoAdd))))
    #expect(
        actions.perform(.run(command: todoAdd, args: ["id": .integer(12)]), as: .host, in: ActionContext())
            == .open(
                CommandRun(
                    command: addTodo, invocation: Invocation(command: todoAdd, args: ["id": .integer(12)]))))
    #expect(
        actions.perform(.run(command: todoDone), as: .host, in: ActionContext())
            == .open(CommandRun(markDone, .invoked)))
    #expect(effects.calls.isEmpty)
}

@MainActor
@Test func builtinsWithoutAnEffectOpenTheirFrame() {
    // How a built-in that shows something plugs in: registered, then run for its frame on the text
    // the action submits.
    let ask = RegisteredCommand(
        id: .builtin("ask"), title: "Ask", icon: .symbol(name: "sparkles"), input: .submitText)
    let registry = CommandRegistry(builtins: builtins + [ask])
    let actions = ActionDispatcher(registry: registry, effects: FakeEffects())
    let question = Invocation(command: ask.id, text: "Capital of France?")
    #expect(
        actions.perform(.run(command: ask.id, text: question.text), as: .host, in: ActionContext())
            == .open(CommandRun(command: ask, invocation: question)))
}

@MainActor
@Test func anUnknownCommandFailsVisiblyWithoutRunning() async {
    let effects = FakeEffects()
    let outcome = dispatcher(effects).perform(
        .run(command: .extension("gone", "away")), as: .host, in: ActionContext())
    guard case .push(let detail, .host) = outcome else {
        Issue.record("expected a failure detail, got \(outcome)")
        return
    }
    #expect(detail.title == "Command Not Found")
    #expect(detail.metadata == [.init(label: "Command", value: "gone/away")])
    #expect(effects.calls.isEmpty)
}

/// A `run` action's revision reaches the invocation, where the extension runner checks it.
@MainActor @Test func aRunKeepsTheRevisionItCameFrom() {
    let revision = ExtensionRevision(extensionID: "todo", sha256: "abc")
    let outcome = dispatcher(FakeEffects()).perform(
        .run(command: todoDone, revision: revision), as: .host, in: ActionContext())
    guard case .open(let run) = outcome else {
        Issue.record("not opened")
        return
    }
    #expect(run.invocation.revision == revision)
    #expect(CommandRun(markDone, .invoked).invocation.revision == nil)
}

// MARK: Authority at activation

private let home = URL(filePath: "/Users/me")
private let app = URL(filePath: "/Applications/Evil.app")
private let script = URL(filePath: "/Users/me/run.sh")
private let notes = URL(filePath: "/Users/me/notes.md")

@MainActor
private func agentEffects() -> FakeEffects {
    let effects = FakeEffects()
    effects.files = [
        app.path: LinkedFile(target: app, isRunnable: false),
        script.path: LinkedFile(target: script, isRunnable: true),
        notes.path: LinkedFile(target: notes, isRunnable: false),
    ]
    return effects
}

@MainActor
private func agentDispatcher(_ effects: FakeEffects) -> ActionDispatcher {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([addTodo, markDone])
    return ActionDispatcher(registry: registry, effects: effects, home: home)
}

/// An agent's Open of an app or a script is revealed when clicked, never run; a document opens.
@MainActor
@Test func anAgentsOpenOfAnAppIsRevealed() {
    let effects = agentEffects()
    let actions = agentDispatcher(effects)
    for url in [app, script, notes] {
        #expect(actions.perform(.open(url: url), as: .agent, in: ActionContext()) == .close)
    }
    #expect(effects.calls == [.reveal(app), .reveal(script), .open(notes)])
    // An extension and the host open what they name: their code runs as the user anyway.
    for authority in [Authority.extension(nil), .host] {
        effects.calls = []
        #expect(actions.perform(.open(url: app), as: authority, in: ActionContext()) == .close)
        #expect(effects.calls == [.open(app)])
    }
}

/// Derived actions are checked like sent ones: a file subject's Open on an app reveals it.
@MainActor
@Test func derivedActionsMeetThePolicyToo() throws {
    let effects = agentEffects()
    let actions = agentDispatcher(effects)
    let row = Item(
        id: "a", title: "Evil.app", icon: .file(url: app), actions: Item.Subject.file(app).actions,
        subject: .file(app))
    let target = ActionTarget(item: row, in: ScreenContext(authority: .agent))
    for index in row.actions.indices {
        #expect(actions.perform(target, at: .action(index), in: ActionContext()) == .close)
    }
    #expect(effects.calls == [.reveal(app), .reveal(app), .copy(app.path)])
}

@MainActor
@Test func anAgentCantRunOrPaste() {
    let effects = agentEffects()
    let actions = agentDispatcher(effects)
    let run = actions.perform(.run(command: todoAdd), as: .agent, in: ActionContext())
    #expect(run == .refused("An agent's reply can't run commands"))
    let paste = actions.perform(.paste(text: "rm -rf ~"), as: .agent, in: ActionContext())
    #expect(paste == .refused("An agent's reply can't paste"))
    let link = actions.perform(.open(url: URL(string: "ssh://host")!), as: .agent, in: ActionContext())
    #expect(link == .refused("Wicket opens only web, mail and file links"))
    #expect(effects.calls.isEmpty)
}

/// A rewrite to Reveal drops the producer's title, so the action panel names what really happens.
@Test func theResolutionNamesTheRealAction() {
    let inspect: (URL) -> LinkedFile? = { $0 == app ? LinkedFile(target: app, isRunnable: false) : nil }
    #expect(
        ActionPolicy.resolve(.open(url: app, title: "Open Notes"), as: .agent, home: home, inspect: inspect)
            == .perform(.reveal(url: app)))
    #expect(
        ActionPolicy.resolve(.open(url: notes, title: "Read"), as: .agent, home: home, inspect: inspect)
            == .perform(.open(url: notes, title: "Read")))
}

/// A file deleted since the screen was drawn: Reveal shows its folder (Open says it's gone).
@MainActor
@Test func revealingAMissingFileRevealsItsFolder() {
    let effects = FakeEffects()
    let gone = URL(filePath: "/Users/me/Documents/gone.pdf")
    #expect(dispatcher(effects).perform(.reveal(url: gone), as: .agent, in: ActionContext()) == .close)
    #expect(effects.calls == [.reveal(URL(filePath: "/Users/me/Documents/"))])
}

/// A page an agent's row pushes is the agent's; the screen's own actions run as the host.
@MainActor
@Test func pagesAndScreenActionsCarryTheirAuthority() {
    let effects = agentEffects()
    let actions = agentDispatcher(effects)
    let page = Detail(markdown: "x")
    #expect(actions.perform(.detail(page), as: .agent, in: ActionContext()) == .push(page, .agent))
    let followUp = Item.Action.run(command: todoAdd, title: "Follow Up")
    let target = ActionTarget(
        actions: [.copy(text: "a"), .open(url: app)],
        in: ScreenContext(authority: .agent, actions: [followUp]))
    #expect(target.secondary == .screen(0))
    guard case .open(let run) = actions.perform(target, at: target.secondary, in: ActionContext()) else {
        Issue.record("the screen's action didn't run as the host's")
        return
    }
    #expect(run.command.id == todoAdd)
    #expect(actions.perform(target, at: .screen(1), in: ActionContext()) == nil)
}
