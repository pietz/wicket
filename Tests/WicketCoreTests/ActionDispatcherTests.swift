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
        case openSettings, quit
    }

    var calls: [Call] = []

    func open(_ url: URL) { calls.append(.open(url)) }
    func copy(_ text: String) { calls.append(.copy(text)) }
    func paste(_ text: String, into app: RunningApp?) { calls.append(.paste(text, app)) }
    func reveal(_ url: URL) { calls.append(.reveal(url)) }
    func openSettings() { calls.append(.openSettings) }
    func quit() { calls.append(.quit) }
}

private let todoAdd = CommandID.extension("todo", "add")
private let todoDone = CommandID.extension("todo", "done")
private let addTodo = RegisteredCommand(id: todoAdd, title: "Add Todo", icon: .symbol(name: "plus"))
private let markDone = RegisteredCommand(
    id: todoDone, title: "Mark as Done", icon: .symbol(name: "checkmark"), isListed: false)

@MainActor
private func dispatcher(_ effects: FakeEffects) -> ActionDispatcher {
    let registry = CommandRegistry()
    registry.setExtensionCommands([addTodo, markDone])
    return ActionDispatcher(registry: registry, effects: effects)
}

private let file = URL(filePath: "/tmp/a.txt")
private let mail = RunningApp(processID: 42, bundleID: "com.apple.mail")

@MainActor
@Test func systemActionsCallTheirEffectAndClose() async {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    let context = ActionContext(previousApp: mail)
    for action in [Item.Action.open(url: file), .copy(text: "42"), .paste(text: "😸"), .reveal(url: file)] {
        #expect(actions.perform(action, in: context) == .close)
    }
    #expect(effects.calls == [.open(file), .copy("42"), .paste("😸", mail), .reveal(file)])
}

@MainActor
@Test func aDetailIsPushedWithoutEffects() async {
    let effects = FakeEffects()
    let page = Detail(title: "Page", markdown: "# Page")
    #expect(dispatcher(effects).perform(.detail(page), in: ActionContext()) == .push(page))
    #expect(effects.calls.isEmpty)
}

@MainActor
@Test func builtinsRunThroughTheRegistry() async {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    #expect(
        actions.perform(.run(command: BuiltinCommand.settings.id), in: ActionContext())
            == .close)
    #expect(
        actions.perform(.run(command: BuiltinCommand.quit.id), in: ActionContext())
            == .close)
    #expect(effects.calls == [.openSettings, .quit])
}

@MainActor
@Test func extensionCommandsOpenTheirFrame() {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    // Opening a listed command, like Return on its row, is a query; one given args or a hidden one
    // is an action, never resent.
    #expect(
        actions.perform(.run(command: todoAdd), in: ActionContext())
            == .open(CommandRun(command: addTodo, invocation: Invocation(command: todoAdd), kind: .query)))
    #expect(
        actions.perform(.run(command: todoAdd, args: ["id": .integer(12)]), in: ActionContext())
            == .open(
                CommandRun(
                    command: addTodo, invocation: Invocation(command: todoAdd, args: ["id": .integer(12)]),
                    kind: .action)))
    #expect(
        actions.perform(.run(command: todoDone), in: ActionContext())
            == .open(CommandRun(command: markDone, invocation: Invocation(command: todoDone), kind: .action)))
    #expect(effects.calls.isEmpty)
}

@MainActor
@Test func builtinsWithoutAnEffectOpenTheirFrame() {
    // How a built-in that shows something (Ask AI) plugs in: registered, then run for its frame.
    let ask = RegisteredCommand(id: .builtin("ask"), title: "Ask AI", icon: .symbol(name: "sparkles"))
    let registry = CommandRegistry(builtins: BuiltinCommand.allCases.map(\.registered) + [ask])
    let actions = ActionDispatcher(registry: registry, effects: FakeEffects())
    let question = Invocation(command: ask.id, args: ["prompt": .string("Capital of France?")])
    #expect(
        actions.perform(.run(command: ask.id, args: question.args), in: ActionContext())
            == .open(CommandRun(command: ask, invocation: question, kind: .action)))
}

@MainActor
@Test func anUnknownCommandFailsVisiblyWithoutRunning() async {
    let effects = FakeEffects()
    let outcome = dispatcher(effects).perform(
        .run(command: .extension("gone", "away")), in: ActionContext())
    guard case .push(let detail) = outcome else {
        Issue.record("expected a failure detail, got \(outcome)")
        return
    }
    #expect(detail.title == "Command Not Found")
    #expect(detail.metadata == [.init(label: "Command", value: "gone/away")])
    #expect(effects.calls.isEmpty)
}
