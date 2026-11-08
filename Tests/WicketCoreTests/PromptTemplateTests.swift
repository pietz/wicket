import Foundation
import Testing

@testable import WicketCore

private func promptManifest(_ commands: [[String: Any]], run: [String]? = nil) throws -> Manifest {
    var object: [String: Any] = [
        "protocol": 1, "id": "prompts", "name": "Prompts", "version": "1.0.0", "commands": commands,
    ]
    if let run { object["run"] = run }
    return try JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func promptOnlyManifestNeedsNoProgramAndGetsContext() throws {
    let manifest = try promptManifest([
        ["id": "german", "title": "German", "prompt": "Translate {selection}. {text} {app} {files}"]
    ])
    #expect(manifest.run.isEmpty)
    #expect(manifest.uvScript == nil)
    let command = try #require(manifest.commands.first)
    #expect(command.placeholders == ["selection", "text", "app", "files"])
    let registered = RegisteredCommand(extension: manifest.id, command: command, icon: nil)
    #expect(registered.usesContext)
    #expect(registered.input == .submitOptionalText)
    #expect(registered.retry == .never)
}

@Test(arguments: [
    "", "   ", "{clipboard}", "{Selection}", "{selection", "selection}", "{{text}}", "{app}{unknown}",
])
func promptTemplatesRejectInvalidPlaceholders(template: String) {
    #expect(throws: (any Error).self) {
        try promptManifest([["id": "go", "title": "Go", "prompt": template]])
    }
}

@Test(arguments: ["live", "root"])
func promptCommandsNeverRunOnTyping(mode: String) {
    #expect(throws: (any Error).self) {
        try promptManifest(
            [["id": "go", "title": "Go", "prompt": "Hello", "mode": mode]], run: ["/bin/false"])
    }
}

@Test func mixedManifestRequiresProgramAndOnlyPromptsGetContext() throws {
    let commands: [[String: Any]] = [
        ["id": "ai", "title": "AI", "prompt": "Hello"], ["id": "local", "title": "Local"],
    ]
    #expect(throws: (any Error).self) { try promptManifest(commands) }
    #expect(throws: (any Error).self) { try promptManifest(commands, run: []) }
    let manifest = try promptManifest(commands, run: ["/bin/false"])
    #expect(
        manifest.commands.map { RegisteredCommand(extension: "prompts", command: $0, icon: nil).usesContext }
            == [true, false])
}

@Test func substitutionIsSinglePassAndMissingContextIsEmpty() throws {
    let context = try #require(
        SummonContext(app: "Mail", text: "literal {text}", files: [URL(filePath: "/tmp/a file")]))
    #expect(
        PromptTemplate.substitute(
            "{selection}|{text}|{app}|{files}|{selection}", text: "literal {app}", context: context)
            == "literal {text}|literal {app}|Mail|/tmp/a file|literal {text}")
    #expect(
        PromptTemplate.substitute("{selection}|{text}|{app}|{files}", text: "typed", context: nil)
            == "|typed||")
}

@Test func promptKeywordsWaitForReturnButRowsAndHotkeysCanUseOnlyTheSelection() throws {
    let manifest = try promptManifest([["id": "go", "title": "Go", "prompt": "Translate {selection}"]])
    let command = RegisteredCommand(extension: "prompts", command: manifest.commands[0], icon: nil)
    for text in ["", "formal"] {
        let typed = CommandRun(command, .keyword, text: text)
        #expect(typed.awaitsText)
        #expect(typed.query == text)
        let frame = ScreenFrame(run: typed)
        #expect(
            frame.target(query: text)?.actions.first == .run(command: command.id, text: text, title: "Go"))
        let invoked = CommandRun(command, .invoked, text: text)
        #expect(!invoked.awaitsText)
        #expect(invoked.query == nil)
        #expect(invoked.invocation.text == text)
    }
}

/// Turning AI off stops every AI use: prompt commands go with Run Agent, so their rows, keywords
/// and hotkeys go inert and an open prompt frame stops; program commands stay.
@MainActor @Test func aiOffUnregistersPromptCommandsAndStopsTheirFrames() async throws {
    let manifest = try promptManifest(
        [
            ["id": "ask", "title": "Ask", "keyword": "ask", "prompt": "Hello {text}"],
            ["id": "local", "title": "Local"],
        ],
        run: ["/bin/false"])
    let commands = manifest.commands.map { RegisteredCommand(extension: "prompts", command: $0, icon: nil) }
    #expect(commands.map(\.feature) == [.ai, nil])
    let registry = CommandRegistry()
    registry.setExtensionCommands(commands)
    let session = PaletteSession(sources: [], runner: Waiting(), registry: registry)
    session.query = "ask "
    session.query = "ask hi"
    #expect(session.frames.count == 2)

    registry.setDisabledFeatures([.ai])
    #expect(registry.command(commands[0].id) == nil)
    #expect(registry.command(keyword: "ask") == nil)
    #expect(registry.command(commands[1].id) != nil)
    // What the app does on every registry change (`AppRuntime.registryChanged`).
    session.stopCommands { registry.command($0) == nil }
    #expect(session.frames.count == 1)

    registry.setDisabledFeatures([])
    #expect(registry.command(commands[0].id) != nil)
}

/// A runner whose runs never answer.
@MainActor
private final class Waiting: CommandRunner {
    func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error> {
        AsyncThrowingStream { _ in }
    }
}
