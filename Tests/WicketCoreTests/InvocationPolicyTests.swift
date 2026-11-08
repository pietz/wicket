import Foundation
import Testing

@testable import WicketCore

// The one invocation policy: a command does the same whether it is reached from its row, a `run`
// action, `wicket run` or its keyword, for each way it takes text; a run is resent only if its
// command says it may be.

@MainActor
private final class Recorder: CommandRunner {
    var runs: [Invocation] = []

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        return AsyncThrowingStream { _ in }
    }
}

@MainActor
private final class Effects: ActionEffects {
    var calls: [String] = []
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}

@MainActor
private func settle(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Commands from manifests, so the translation is part of what is checked.
private func manifestCommands() throws -> [RegisteredCommand] {
    let json = #"""
        {"protocol":2,"id":"todo","name":"Todo","version":"1.0.0","run":["/bin/sh","x.sh"],"commands":[
          {"id":"toggle","title":"Toggle Dark Mode","keyword":"dark"},
          {"id":"list","title":"List Todos","keyword":"todos"},
          {"id":"find","title":"Find Todos","keyword":"find","mode":"live"},
          {"id":"done","title":"Mark Done","hidden":true}
        ]}
        """#
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    return manifest.commands.map { RegisteredCommand(extension: manifest.id, command: $0, icon: nil) }
}

/// One palette over the built-ins and the manifest's commands.
@MainActor
private struct Palette {
    let registry = CommandRegistry(builtins: builtins)
    let effects = Effects()
    let runner = Recorder()
    let session: PaletteSession
    let dispatcher: ActionDispatcher

    init() throws {
        registry.setExtensionCommands(try manifestCommands())
        session = PaletteSession(
            sources: [CommandsSource(registry), FallbackSource(registry)], runner: runner, registry: registry,
            liveDebounce: .zero)
        dispatcher = ActionDispatcher(registry: registry, effects: effects)
    }

    func command(_ id: CommandID) throws -> RegisteredCommand { try #require(registry.command(id)) }

    /// Return on the command's root row: the action its row carries.
    func row(_ id: CommandID) throws -> ActionOutcome {
        let item = try #require(registry.search("").first { $0.id == CommandRegistry.itemID(for: id) })
        return dispatcher.perform(item.actions[0], as: .host, in: ActionContext())
    }

    /// A `run` action naming the command, without text.
    func runAction(_ id: CommandID) -> ActionOutcome {
        dispatcher.perform(.run(command: id), as: .host, in: ActionContext())
    }

    /// `wicket run <folder> <command> [text]`: the CLI resolves the manifest command the same way.
    func cli(_ id: CommandID, text: String = "") throws -> CommandRun {
        CommandRun(try command(id), .invoked, text: text)
    }

    var commandFrame: Frame? { session.top.results == nil ? session.top : nil }
}

private let toggle = CommandID.extension("todo", "toggle")
private let list = CommandID.extension("todo", "list")
private let find = CommandID.extension("todo", "find")

@MainActor @Test func manifestsTranslateIntoInput() throws {
    let commands = Dictionary(uniqueKeysWithValues: try manifestCommands().map { ($0.id.name, $0) })
    #expect(commands["toggle"]?.input == .immediateText)
    #expect(commands["find"]?.input == .liveText)
}

@MainActor @Test func aCommandWithoutTextRunsTheSameFromItsRowAndARunAction() throws {
    let palette = try Palette()
    // It opens like any command; its runner does the effect and closes before a frame shows.
    let opened = ActionOutcome.open(CommandRun(.settings, .invoked))
    #expect(try palette.row(CommandID.settings) == opened)
    #expect(palette.runAction(CommandID.settings) == opened)
}

@MainActor @Test func anImmediateCommandRunsNowFromEveryWayIn() async throws {
    let palette = try Palette()
    let expected = CommandRun(
        command: try palette.command(toggle), invocation: Invocation(command: toggle))
    #expect(try palette.row(toggle) == .open(expected))
    #expect(palette.runAction(toggle) == .open(expected))
    #expect(try palette.cli(toggle) == expected)

    // From its keyword: the rest of the line is its text, and the frame shows at once so further
    // typing filters it. The run is the same, never resent.
    palette.session.query = "dark now"
    #expect(palette.session.frames.count == 2)
    #expect(palette.commandFrame?.run?.invocation == Invocation(command: toggle, text: "now"))
    #expect(palette.session.query == "")
    #expect(await settle { palette.runner.runs.last == Invocation(command: toggle, text: "now") })
}

@MainActor @Test func aLiveCommandShowsItsFrameAtOnceFromEveryWayIn() async throws {
    let palette = try Palette()
    let expected = CommandRun(command: try palette.command(find), invocation: Invocation(command: find))
    #expect(try palette.row(find) == .open(expected))
    #expect(palette.runAction(find) == .open(expected))
    #expect(try palette.cli(find, text: "milk").invocation.text == "milk")

    palette.session.query = "find milk"
    #expect(palette.commandFrame?.run?.command.id == find)
    #expect(palette.session.query == "milk")
    #expect(await settle { palette.runner.runs.last?.text == "milk" })
}

@MainActor @Test func aSubmitTextCommandWaitsForItsTextUnlessItWasSubmitted() async throws {
    let palette = try Palette()
    let ask = try palette.command(CommandID.runAgent)
    let waiting = CommandRun(command: ask, invocation: Invocation(command: CommandID.runAgent))
    // A `run` without text opens its frame waiting for the text; nothing runs.
    #expect(palette.runAction(CommandID.runAgent) == .open(waiting))
    #expect(waiting.awaitsText)
    #expect(CommandRun(ask, .invoked, text: "  ") == waiting)
    // Submitted text (its fallback row, a `run` with text) runs now.
    #expect(
        CommandRun(ask, .invoked, text: "why")
            == CommandRun(
                command: ask, invocation: Invocation(command: CommandID.runAgent, text: "why"))
    )

    // Its keyword puts what followed it in the waiting frame's field; never runs it.
    palette.session.query = "ai why is the sky blue"
    #expect(palette.commandFrame?.run?.invocation == waiting.invocation)
    #expect(palette.commandFrame?.run?.awaitsText == true)
    #expect(palette.session.query == "why is the sky blue")
    #expect(palette.session.top.isCompact)
    #expect(!palette.session.top.isLoading)
    palette.session.query = "why is the sky blue?"
    try? await Task.sleep(for: .milliseconds(20))
    #expect(palette.runner.runs.isEmpty)

    // Return submits the field, which runs it in a frame of its own; Escape goes back to the question.
    let target = try #require(palette.session.top.target)
    #expect(target.actions == [asking("why is the sky blue?")])
    #expect(target.item == nil)
    guard case .open(let run) = palette.dispatcher.perform(target.actions[0], as: .host, in: ActionContext())
    else {
        Issue.record("submitting didn't open a run")
        return
    }
    palette.session.open(run)
    #expect(await settle { palette.runner.runs.count == 1 })
    #expect(palette.runner.runs[0].text == "why is the sky blue?")
    #expect(palette.session.back())
    #expect(palette.session.query == "why is the sky blue?")

    // An empty field has nothing to submit.
    palette.session.query = ""
    #expect(palette.session.top.target == nil)
}

@MainActor @Test func runAgentKeepsItsKeywordAgainstAnExtension() async throws {
    let rival = RegisteredCommand(
        id: .extension("assistant", "chat"), title: "Assistant", icon: .symbol(name: "bubble"), keyword: "ai")
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([rival])
    #expect(registry.command(keyword: "ai")?.id == CommandID.runAgent)
    #expect(
        registry.keywordConflicts
            == [CommandRegistry.KeywordConflict(keyword: "ai", winner: CommandID.runAgent, loser: rival.id)])

    // So "ai " opens Run Agent, waiting for the question, and the extension is never run.
    let runner = Recorder()
    let session = PaletteSession(sources: [], runner: runner, registry: registry, liveDebounce: .zero)
    session.query = "ai "
    guard case let frame = session.top, frame.results == nil else {
        Issue.record("no frame")
        return
    }
    #expect(frame.run?.command.id == CommandID.runAgent)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(runner.runs.isEmpty)

    // With Run Agent off, the extension has the word.
    registry.setAIEnabled(false)
    #expect(registry.command(keyword: "ai")?.id == rival.id)
}

@Test func submittingAWaitingFrameKeepsItsInvocation() {
    // A `run` action with args from an extension's row opens a frame waiting for text; submitting
    // replaces only the text, so the args and the revision the row came from still go with it.
    let id = CommandID.extension("notes", "add")
    let command = RegisteredCommand(
        id: id, title: "Add Note", icon: .symbol(name: "note"), input: .submitText)
    let revision = ExtensionRevision(extensionID: "notes", sha256: "abc")
    let invocation = Invocation(command: id, args: ["folder": .string("work")], revision: revision)
    var frame = Frame(id: 1, run: CommandRun(command: command, invocation: invocation))
    frame.query = "buy milk"
    #expect(frame.run?.awaitsText == true)
    #expect(
        frame.target?.actions == [
            .run(
                command: id, text: "buy milk", args: ["folder": .string("work")], title: "Add Note",
                revision: revision)
        ])
}
