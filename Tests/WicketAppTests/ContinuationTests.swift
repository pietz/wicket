import AppKit
import Foundation
import Testing
import WicketCore

@testable import WicketApp

@MainActor
private final class ContinuationRunner: CommandRunner {
    let result: RunResult
    var invocations: [Invocation] = []

    init(_ result: RunResult) { self.result = result }

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        invocations.append(invocation)
        return AsyncThrowingStream {
            $0.yield(result)
            $0.finish()
        }
    }
}

@MainActor
private struct NoContinuationEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}

/// Drives the same controller callback as a typed key, with a panel that is never shown.
@MainActor @Test(arguments: ["shell", "ai-prose", "ai-rows"])
func typingOnResultsWaitsForReturnAndPreservesTheFirstText(kind: String) async throws {
    let shell = kind == "shell"
    let next = shell ? CommandID.runShell : .builtin("follow-up")
    let args: [String: JSONValue]? = shell ? nil : ["conversation": .string("kept-session")]
    let continuation = Item.Action.run(command: next, args: args, title: shell ? "New Command" : "Follow Up")
    let markdown = kind == "ai-rows" ? "<file path=\"/tmp/alpha.txt\"/>" : "The result."
    let context = ScreenContext(authority: shell ? .host : .agent, actions: [continuation])
    let runner = ContinuationRunner(.show(.detail(Detail(markdown: markdown)), context))
    let source = RegisteredCommand(
        id: .builtin("result"), title: "Result", icon: .symbol(name: "doc"), input: .none)
    let submit = RegisteredCommand(
        id: next, title: "Continue", icon: .symbol(name: "terminal"), input: .submitText)
    let registry = CommandRegistry(builtins: [source, submit])
    let url = FileManager.default.temporaryDirectory.appending(
        path: "wicket-continuation-\(UUID())/usage.json")
    let model = PaletteModel(sources: [], runner: runner, registry: registry, usageURL: url)
    let controller = PaletteController(
        model: model, dispatcher: ActionDispatcher(registry: registry, effects: NoContinuationEffects()))
    model.session.open(CommandRun(source, .invoked))
    #expect(await eventually { !model.top.isLoading })
    let result = model.top.id
    #expect(model.showsTitle)
    #expect(model.session.typingAction == continuation)
    if kind == "ai-rows" {
        #expect(model.top.listing != nil && !model.top.isMeasured)
        #expect(model.top.target?.item?.title == "alpha.txt")
    }

    #expect(controller.type("ü"))
    await Task.yield()
    #expect(runner.invocations.count == 1)
    #expect(model.top.awaitsText && !model.showsTitle)
    #expect(model.query == "ü")
    #expect(model.top.run?.invocation.args == args)
    #expect(model.session.back())
    #expect(model.top.id == result)

    #expect(controller.type("echo"))
    model.query += " next"
    controller.run(model.target, at: .action(0))
    #expect(await eventually { runner.invocations.count == 2 })
    #expect(runner.invocations.last?.text == "echo next")
    #expect(runner.invocations.last?.command == next)
    #expect(runner.invocations.last?.args == args)
    model.session.reset()
}
