import Foundation
import Testing

@testable import WicketCore

@MainActor
private final class ShellProbe: CommandRunner, ResultSource {
    let id = "probe"
    var searches = 0
    var runs: [Invocation] = []

    func instant(_ query: Query) -> [Item] {
        searches += 1
        return []
    }

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        runs.append(invocation)
        return AsyncThrowingStream {
            $0.yield(.show(.detail(Detail(markdown: "done"))))
            $0.finish()
        }
    }
}

@MainActor @Test func shellPrefixWaitsForSubmitAndOwnsTheQuery() async throws {
    let commands = [CommandID.runShell, .runInTerminal].map {
        RegisteredCommand(
            id: $0, title: $0.name, icon: .symbol(name: "terminal"),
            isListed: false, input: .submitText)
    }
    let registry = CommandRegistry(builtins: commands)
    let probe = ShellProbe()
    let session = PaletteSession(sources: [probe], runner: probe, registry: registry)
    for text in [">", "> ", ">p", ">printf '%s' 'a b'"] { session.query = text }
    await Task.yield()
    #expect(probe.runs.isEmpty)
    #expect(probe.searches == 0)
    #expect(session.frames.count == 1)
    let target = try #require(session.top.target)
    #expect(
        target.actions == [
            .run(command: .runShell, text: "printf '%s' 'a b'", title: "Run in Wicket"),
            .run(command: .runInTerminal, text: "printf '%s' 'a b'", title: "Run in Terminal"),
        ])
    session.open(CommandRun(commands[0], .invoked, text: "printf '%s' 'a b'"))
    for _ in 0..<100 where probe.runs.isEmpty { await Task.yield() }
    #expect(probe.runs.map(\.text) == ["printf '%s' 'a b'"])
    #expect(session.back())
    #expect(session.query == ">printf '%s' 'a b'")
}

@Test func shellPrefixAndDestinationsAreExplicit() {
    #expect(ShellCommand.text(in: "ls > out", prefix: ">") == nil)
    #expect(ShellCommand.text(in: ">>printf x\n", prefix: ">>") == "printf x\n")
    #expect(ShellCommand.text(in: "echo x", prefix: "") == nil)
    #expect(!Settings.Shell.validPrefix("ai"))
    #expect(!Settings.Shell.validPrefix("> "))
    var settings = Settings.Shell()
    settings.destination = .terminal
    let row = ShellCommand.item(text: "echo x", settings: settings)
    #expect(row.actions.first == .run(command: .runInTerminal, text: "echo x", title: "Run in Terminal"))
    #expect(ShellCommand.item(text: " \n", settings: settings).actions.isEmpty)
}
