import Foundation
import Testing

@testable import WicketCore

/// Records every effect; `run` answers with `result` or throws `failure`.
@MainActor
private final class FakeEffects: ActionEffects {
    enum Call: Equatable {
        case open(URL)
        case copy(String)
        case paste(String, RunningApp?)
        case reveal(URL)
        case openSettings, quit
        case run(Invocation)
    }

    var calls: [Call] = []
    var result = RunResult.close(message: nil)
    var failure: (any Error)?

    func open(_ url: URL) { calls.append(.open(url)) }
    func copy(_ text: String) { calls.append(.copy(text)) }
    func paste(_ text: String, into app: RunningApp?) { calls.append(.paste(text, app)) }
    func reveal(_ url: URL) { calls.append(.reveal(url)) }
    func openSettings() { calls.append(.openSettings) }
    func quit() { calls.append(.quit) }

    func run(_ invocation: Invocation) async throws -> RunResult {
        calls.append(.run(invocation))
        if let failure { throw failure }
        return result
    }
}

private struct Failure: Error, CustomStringConvertible {
    var description: String { "no response within 30 s" }
}

private let todoAdd = CommandID.extension("todo", "add")

@MainActor
private func dispatcher(_ effects: FakeEffects) -> ActionDispatcher {
    let registry = CommandRegistry()
    registry.setExtensionCommands([
        RegisteredCommand(id: todoAdd, title: "Add Todo", icon: .symbol(name: "plus"))
    ])
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
        #expect(await actions.perform(action, in: context) == .close(message: nil))
    }
    #expect(effects.calls == [.open(file), .copy("42"), .paste("😸", mail), .reveal(file)])
}

@MainActor
@Test func aDetailIsPushedWithoutEffects() async {
    let effects = FakeEffects()
    let page = Detail(title: "Page", markdown: "# Page")
    #expect(await dispatcher(effects).perform(.detail(page), in: ActionContext()) == .push(.detail(page)))
    #expect(effects.calls.isEmpty)
}

@MainActor
@Test func builtinsRunThroughTheRegistry() async {
    let effects = FakeEffects()
    let actions = dispatcher(effects)
    #expect(
        await actions.perform(.run(command: BuiltinCommand.settings.id), in: ActionContext())
            == .close(message: nil))
    #expect(
        await actions.perform(.run(command: BuiltinCommand.quit.id), in: ActionContext())
            == .close(message: nil))
    #expect(effects.calls == [.openSettings, .quit])
}

@MainActor
@Test func extensionRunsGetTheirArgsAndEmptyText() async {
    let effects = FakeEffects()
    _ = await dispatcher(effects).perform(
        .run(command: todoAdd, args: ["id": .integer(12)]), in: ActionContext())
    #expect(effects.calls == [.run(Invocation(command: todoAdd, text: "", args: ["id": .integer(12)]))])
}

@MainActor
@Test func runResultsMapToOutcomes() async {
    let item = Item(id: "ext:todo/add:1", title: "Added", icon: .symbol(name: "checkmark"), actions: [])
    let page = Detail(markdown: "Done")
    let cases: [(RunResult, ActionOutcome)] = [
        (.answer(item), .push(.answer(item))),
        (.list([item]), .push(.list([item]))),
        (.detail(page), .push(.detail(page))),
        (.close(message: "Added"), .close(message: "Added")),
        (.reload(message: nil), .reload(message: nil)),
    ]
    for (result, outcome) in cases {
        let effects = FakeEffects()
        effects.result = result
        #expect(await dispatcher(effects).perform(.run(command: todoAdd), in: ActionContext()) == outcome)
    }
}

@MainActor
@Test func aFailedRunIsShownAsADetail() async {
    let effects = FakeEffects()
    effects.failure = Failure()
    let outcome = await dispatcher(effects).perform(.run(command: todoAdd), in: ActionContext())
    #expect(
        outcome
            == .push(
                .detail(
                    Detail(
                        title: "Add Todo Failed", markdown: "no response within 30 s",
                        metadata: [.init(label: "Command", value: "todo/add")]))))
}

@MainActor
@Test func aCancelledRunStays() async {
    let effects = FakeEffects()
    effects.failure = CancellationError()
    #expect(await dispatcher(effects).perform(.run(command: todoAdd), in: ActionContext()) == .stay)
}

@MainActor
@Test func anUnknownCommandFailsVisiblyWithoutRunning() async {
    let effects = FakeEffects()
    let outcome = await dispatcher(effects).perform(
        .run(command: .extension("gone", "away")), in: ActionContext())
    guard case .push(.detail(let detail)) = outcome else {
        Issue.record("expected a failure detail, got \(outcome)")
        return
    }
    #expect(detail.title == "Command Not Found")
    #expect(detail.metadata == [.init(label: "Command", value: "gone/away")])
    #expect(effects.calls.isEmpty)
}
