import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Wicket extending itself through an acting run: the agent is told Wicket's commands and where
// extensions go, and what it adds or changes there is offered for review once it has answered.

/// Extensions over a fresh folder holding `folders`, with `approved` approved.
@MainActor
private func extensions(_ folders: [TestExtension], approved: Set<String> = []) async throws -> Extensions {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/authoring-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for ext in folders {
        try FileManager.default.moveItem(
            at: ext.folder, to: directory.appending(path: ext.folder.lastPathComponent))
    }
    let extensions = Extensions(
        directory: directory, store: testStore(), approvals: testApprovals(), history: testHistory()
    ) { _ in testConfiguration() }
    await extensions.load().value
    for found in extensions.discovered where approved.contains(found.id) {
        try await extensions.approve(try #require(found.sealed).revision)
    }
    return extensions
}

/// The repository: its layout is the bundled authoring kit's (docs/…, Extensions/…).
private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

/// Authoring over `extensions` with the repository's default instructions, its own instructions
/// file and command list in a folder beside the extensions folder, and no kit or tool unless given.
@MainActor
private func testAuthoring(
    _ extensions: Extensions, commands: [RegisteredCommand] = [], kit: URL? = nil, tool: URL? = nil
) -> ExtensionAuthoring {
    let host = extensions.directory.deletingLastPathComponent().appending(
        path: extensions.directory.lastPathComponent + "-host")
    return ExtensionAuthoring(
        extensions: extensions, commands: { commands }, instructionsFile: host.appending(path: "agent.md"),
        commandList: host.appending(path: "commands.md"),
        defaultInstructions: repository.appending(path: "Resources/agent.md"), kit: kit, tool: tool)
}

private func plain(_ id: String) throws -> TestExtension {
    try TestExtension(id: id, script: answering(#"{"answer":{"title":"hi"}}"#))
}

/// The requests an agent was sent.
private final class Requests: Sendable {
    private let requests = Mutex<[AgentRequest]>([])
    func append(_ request: AgentRequest) { requests.withLock { $0.append(request) } }
    var first: AgentRequest? { requests.withLock { $0.first } }
    var last: AgentRequest? { requests.withLock { $0.last } }
    var all: [AgentRequest] { requests.withLock { $0 } }
}

/// An agent that runs `body` (writing files, say) and then sends `events`, by default an answer.
private func agent(
    _ requests: Requests,
    events sent: [AgentEvent] = [.answer("Made it; review and enable it in Wicket.")],
    _ body: @escaping @Sendable () throws -> Void
) -> AgentBackend {
    AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in
            requests.append(request)
            return AgentRun { events in
                try? body()
                for event in sent { events.yield(event) }
                return .exited(.status(0))
            }
        })
}

@MainActor
private func finalDetail(
    _ runner: AgentRunner, _ question: String, args: [String: JSONValue]? = nil
) async throws -> Detail? {
    var last: Detail?
    for try await result in runner.run(
        Invocation(command: .runAgent, text: question, args: args), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { last = detail }
    }
    return last
}

@MainActor @Test func actingRunsAreToldTheInstructionsThenTheirPaths() async throws {
    let extensions = try await extensions([])
    let commands = [
        RegisteredCommand(id: .builtin("settings"), title: "Wicket Settings", icon: .symbol(name: "gear")),
        RegisteredCommand(
            id: .extension("weather", "today"), title: "Weather", subtitle: "Today's forecast",
            icon: .symbol(name: "sun.max"), keyword: "w", input: .liveText),
        RegisteredCommand(
            id: .builtin("hidden"), title: "Hidden Thing", icon: .symbol(name: "eye"), isListed: false),
    ]
    let tool = URL(filePath: "/W.app/Contents/Helpers/wicket")
    let authoring = testAuthoring(extensions, commands: commands, kit: repository, tool: tool)
    let text = authoring.instructions()
    let bundled = try String(contentsOf: repository.appending(path: "Resources/agent.md"), encoding: .utf8)
    #expect(text.hasPrefix(bundled.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## This Wicket\n"))
    #expect(text.contains("- Extensions folder: \(extensions.directory.path)\n"))
    #expect(text.contains("- Authoring guide: \(repository.path)/docs/extensions.md\n"))
    #expect(text.contains("- Schema: \(repository.path)/docs/extension.schema.json\n"))
    #expect(
        text.contains(
            "\(repository.path)/docs/examples/unicode, \(repository.path)/docs/examples/week-number"))
    #expect(text.contains("`\(tool.path) check <folder>`"))
    #expect(text.contains("- Command list: \(authoring.commandList.path)"))

    // The command list holds every command, hidden ones too, with its id, input and folder.
    let list = try String(contentsOf: authoring.commandList, encoding: .utf8)
    #expect(list.contains("- `builtin:hidden` Hidden Thing. Runs at once (mode `once`). Not in search"))
    #expect(
        list.contains(
            "- `ext:weather/today` Weather: Today's forecast. Keyword `w`. Runs again as the text changes "
                + "(mode `live`). Folder: \(extensions.directory.appending(path: "weather").path)\n"))

    // Without a kit or tool, the paths say so rather than naming files that aren't there.
    let without = testAuthoring(extensions).instructions()
    #expect(without.contains("- Authoring guide: none in this build"))
    #expect(!without.contains("`wicket` tool:"))

    // The instructions go to Codex as its developer instructions.
    var transcript = CodexTranscript(
        request: AgentRequest(
            prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"),
            options: AgentProvider.claude.defaultOptions, instructions: text))
    let start = transcript.start()
    guard case .object(let thread)? = try? JSONDecoder().decode(JSONValue.self, from: start.send[2]) else {
        Issue.record("no thread/start")
        return
    }
    #expect(thread["params"]?["developerInstructions"] == .string(text))
}

/// The user's agent.md replaces the default and is read again for every run; deleting it restores the
/// default, and opening it from Settings writes the default there first.
@MainActor @Test func theUsersInstructionsFileReplacesTheDefault() async throws {
    let extensions = try await extensions([])
    let authoring = testAuthoring(extensions)
    let file = authoring.instructionsFile
    #expect(authoring.instructions().hasPrefix("<!-- Wicket's instructions"))

    #expect(
        try ExtensionAuthoring.editableInstructions(file: file, default: authoring.defaultInstructions)
            == file)
    let written = try String(contentsOf: file, encoding: .utf8)
    #expect(written == (try String(contentsOf: try #require(authoring.defaultInstructions), encoding: .utf8)))

    try "Always answer in French.".write(to: file, atomically: true, encoding: .utf8)
    #expect(authoring.instructions().hasPrefix("Always answer in French.\n\n## This Wicket"))
    // An existing file is opened as it is, never overwritten.
    _ = try ExtensionAuthoring.editableInstructions(file: file, default: authoring.defaultInstructions)
    #expect(try String(contentsOf: file, encoding: .utf8) == "Always answer in French.")

    try "".write(to: file, atomically: true, encoding: .utf8)
    #expect(authoring.instructions().hasPrefix("## This Wicket"))

    try FileManager.default.removeItem(at: file)
    #expect(authoring.instructions().hasPrefix("<!-- Wicket's instructions"))
}

@MainActor @Test func anActingRunOffersToReviewTheExtensionsItWrote() async throws {
    let extensions = try await extensions(
        [try plain("enabled"), try plain("untouched"), try plain("edited")], approved: ["enabled", "edited"])
    let directory = extensions.directory
    let made = try plain("weather")
    let requests = Requests()
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(requests) {
                try FileManager.default.copyItem(at: made.folder, to: directory.appending(path: "weather"))
                let script = directory.appending(path: "edited/main.sh")
                try (String(contentsOf: script, encoding: .utf8) + "\n# v2\n").write(
                    to: script, atomically: false, encoding: .utf8)
            }, provider: { .codex }))
    runner.answers.authoring = testAuthoring(extensions)

    let detail = try #require(try await finalDetail(runner, "build a weather command"))
    // The new folder and the changed approved one, by id; not the untouched or unchanged ones.
    #expect(
        detail.actions.compactMap { $0.title } == [
            "Review and Enable Test", "Review and Enable Test", "Copy Answer", "Paste Answer",
        ])
    let ids = detail.actions.prefix(2).compactMap { action -> String? in
        guard case .run(.reviewExtension, _, let args?, _, _) = action, case .string(let id)? = args["id"]
        else { return nil }
        return id
    }
    #expect(ids == ["edited", "weather"])
    let request = try #require(requests.first)
    #expect(request.instructions?.contains(directory.path) == true)
}

@MainActor @Test func aRunThatFailedAfterWritingAnExtensionStillOffersItsReview() async throws {
    let extensions = try await extensions([])
    let directory = extensions.directory
    let made = try plain("weather")
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(
                Requests(), events: [.message("Writing it"), .error("Claude Code was interrupted")]
            ) {
                try FileManager.default.copyItem(at: made.folder, to: directory.appending(path: "weather"))
            }, provider: { .claude }))
    runner.answers.authoring = testAuthoring(extensions)
    let detail = try #require(try await finalDetail(runner, "build a weather command"))
    #expect(detail.actions.compactMap { $0.title } == ["Review and Enable Test", "Retry", "Copy Answer"])

    // With nothing streamed, the failure page offers it too.
    let silent = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests(), events: [.error("stopped")]) {
                let script = directory.appending(path: "weather/main.sh")
                try (String(contentsOf: script, encoding: .utf8) + "\n# v2\n").write(
                    to: script, atomically: false, encoding: .utf8)
            }, provider: { .claude }))
    silent.answers.authoring = runner.answers.authoring
    let failure = try #require(try await finalDetail(silent, "change it"))
    #expect(failure.actions.compactMap { $0.title } == ["Review and Enable Test", "Retry"])
}

@MainActor @Test func aRunCanNameItsFrame() async throws {
    let runner = AgentRunner(
        answers: AnswerStream(backend: agent(Requests()) {}, provider: { .claude }))
    let detail = try #require(
        try await finalDetail(
            runner, "Fix my Wicket extension Test in /tmp/x.\n\nIt failed Wicket's check: a long report",
            args: ["title": .string("Fix Test")]))
    #expect(detail.title == "Fix Test")
}

@MainActor @Test func aFailedCheckOffersToFixItWithTheAgent() async throws {
    // No fixture, so the check fails.
    let extensions = try await extensions([try plain("broken")])
    let runner = ExtensionsRunner(extensions: extensions, checkOptions: checkOptions())
    var last: Detail?
    for try await result in runner.run(
        Invocation(command: .reviewExtension, args: ["id": .string("broken")]), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { last = detail }
    }
    let detail = try #require(last)
    #expect(!detail.actions.contains { $0.title == "Enable" })
    let fix = try #require(detail.actions.first { $0.title == "Fix with Agent" })
    guard case .run(.runAgent, let text, let args, _, nil) = fix else {
        Issue.record("not a Run Agent run: \(fix)")
        return
    }
    // The frame is titled by the extension; the whole failure goes to the agent, in a run about the
    // extension, which says which one it is.
    #expect(args == ["title": .string("Fix Test"), "extension": .string("broken")])
    #expect(text.hasPrefix("Find out why it fails and fix it.\n\nIt failed Wicket's check:"))
}

/// The real thing, on the user's Codex subscription: a headless `codex app-server` asked for a
/// command writes an extension into the folder, Wicket offers its review, and it passes its check.
/// Opt in with `WICKET_TEST_CODEX=1` and a `CODEX_HOME` holding only `auth.json` and a config.toml
/// with `approval_policy = "never"` and `sandbox_mode = "workspace-write"`.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_TEST_CODEX"] == "1"))
func codexBuildsACommandThatWicketOffersForReview() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/codex-\(UUID().uuidString)"
    )
    .resolvingSymlinksInPath()
    let directory = root.appending(path: "Extensions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    let runner = AgentRunner(answers: AnswerStream(provider: { .codex }))
    runner.answers.authoring = testAuthoring(extensions, kit: repository)
    var last: Detail?
    for try await result in runner.run(
        Invocation(
            command: .runAgent, text: "Build an extension that shows the current ISO week number in Wicket.",
            context: SummonContext(files: [root])), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { last = detail }
    }
    let detail = try #require(last)
    print("ANSWER:\n\(detail.markdown)\nACTIONS: \(detail.actions.compactMap(\.title))")
    let review = try #require(detail.actions.first)
    guard case .run(.reviewExtension, _, let args?, _, _) = review, case .string(let id)? = args["id"] else {
        Issue.record("no review offered: \(detail.actions)")
        return
    }
    let consent = ExtensionsRunner(
        extensions: extensions, checkOptions: checkOptions { $0.requestTimeout = .seconds(30) })
    var page: Detail?
    for try await result in consent.run(
        Invocation(command: .reviewExtension, args: ["id": .string(id)]), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { page = detail }
    }
    print("REVIEW:\n\(page?.markdown ?? "-")\nACTIONS: \(page?.actions.compactMap(\.title) ?? [])")
    #expect(page?.actions.first?.title == "Enable")
}

/// The same with Claude Code, on the user's subscription with Wicket's defaults (Sonnet on Auto, which
/// lets it write in the folder without asking).
/// Opt in with `WICKET_TEST_CLAUDE=1`.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_TEST_CLAUDE"] == "1"))
func claudeBuildsACommandThatWicketOffersForReview() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/claude-\(UUID().uuidString)"
    )
    .resolvingSymlinksInPath()
    let directory = root.appending(path: "Extensions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    let runner = AgentRunner(answers: AnswerStream(provider: { .claude }))
    runner.answers.authoring = testAuthoring(extensions, kit: repository)
    var last: Detail?
    for try await result in runner.run(
        Invocation(
            command: .runAgent, text: "Build an extension that shows the current ISO week number in Wicket.",
            context: SummonContext(files: [root])), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { last = detail }
    }
    let detail = try #require(last)
    print("ANSWER:\n\(detail.markdown)\nACTIONS: \(detail.actions.compactMap(\.title))")
    let review = try #require(detail.actions.first)
    guard case .run(.reviewExtension, _, let args?, _, _) = review, case .string(let id)? = args["id"] else {
        Issue.record("no review offered: \(detail.actions)")
        return
    }
    let consent = ExtensionsRunner(
        extensions: extensions, checkOptions: checkOptions { $0.requestTimeout = .seconds(30) })
    var page: Detail?
    for try await result in consent.run(
        Invocation(command: .reviewExtension, args: ["id": .string(id)]), retry: .never)
    {
        if case .show(.detail(let detail), _) = result { page = detail }
    }
    print("REVIEW:\n\(page?.markdown ?? "-")\nACTIONS: \(page?.actions.compactMap(\.title) ?? [])")
    #expect(page?.actions.first?.title == "Enable")
}

@MainActor @Test func aBrokenExtensionEditedWithTheSameErrorIsStillOffered() async throws {
    let broken = try plain("broken")
    try FileManager.default.removeItem(at: broken.folder.appending(path: "wicket.json"))
    let extensions = try await extensions([broken])
    let directory = extensions.directory
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests()) {
                // Still no manifest, so the same error; but the folder changed.
                try "echo v2".write(
                    to: directory.appending(path: "broken/main.sh"), atomically: false, encoding: .utf8)
            }, provider: { .codex }))
    runner.answers.authoring = testAuthoring(extensions)
    let detail = try #require(try await finalDetail(runner, "fix it"))
    #expect(detail.actions.first?.title == "Review and Enable broken")
}

@MainActor @Test func aChangeMadeBeforeTheRunIsNotTheRunsWork() async throws {
    let extensions = try await extensions([])
    // Written before the run, before any watcher event arrives.
    try FileManager.default.copyItem(
        at: try plain("earlier").folder, to: extensions.directory.appending(path: "earlier"))
    let runner = AgentRunner(
        answers: AnswerStream(backend: agent(Requests()) {}, provider: { .codex }))
    runner.answers.authoring = testAuthoring(extensions)
    let detail = try #require(try await finalDetail(runner, "what's the time?"))
    #expect(!detail.actions.contains { $0.title?.hasPrefix("Review") == true })
}

@MainActor @Test func longTitlesAreClippedInTheCommandList() async throws {
    let extensions = try await extensions([])
    let long = String(repeating: "x", count: 5000)
    let commands = [
        RegisteredCommand(id: .builtin("odd"), title: long, icon: .symbol(name: "gear"), keyword: long)
    ]
    let authoring = testAuthoring(extensions, commands: commands)
    _ = authoring.instructions()
    #expect(try String(contentsOf: authoring.commandList, encoding: .utf8).count < 1500)
}

// MARK: The build conversation

/// An agent that records its requests and answers each; one asked to resume a session fails at once
/// when `resumes` is false, as a CLI does for a session it no longer has.
private func resumingAgent(_ requests: Requests, resumes: Bool = true) -> AgentBackend {
    AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in
            requests.append(request)
            return AgentRun { events in
                if request.resume != nil, !resumes {
                    events.yield(.error("No conversation found with that session ID"))
                } else {
                    events.yield(.session(request.resume ?? "new-session"))
                    events.yield(.answer("Fixed it."))
                }
                return .exited(.status(0))
            }
        })
}

@MainActor @Test func aRunThatBuildsAnExtensionIsRememberedAsItsConversation() async throws {
    let extensions = try await extensions([])
    let directory = extensions.directory
    let made = try plain("weather")
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests(), events: [.session("s9"), .answer("Made it.")]) {
                try FileManager.default.copyItem(at: made.folder, to: directory.appending(path: "weather"))
            }, provider: { .claude }))
    runner.answers.authoring = testAuthoring(extensions)
    _ = try await finalDetail(runner, "build a weather command")
    let history = try #require(extensions.history)
    let remembered = try #require(await history.conversation(of: "weather"))
    #expect(remembered.session == "s9" && remembered.provider == .claude)
    // Never in the extension's own folder, which is sealed.
    #expect(
        !FileManager.default.fileExists(atPath: directory.appending(path: "weather/conversation.json").path))
}

@MainActor @Test func fixWithAgentResumesTheConversationThatBuiltTheExtension() async throws {
    let extensions = try await extensions([try plain("weather")], approved: ["weather"])
    let history = try #require(extensions.history)
    let built = URL(filePath: "/tmp/where-it-was-built")
    await history.remember(
        AnswerStream.Conversation(
            provider: .codex, folder: built,
            options: AgentOptions(model: "gpt-x"),
            session: "thread-1"),
        for: "weather")
    let requests = Requests()
    let runner = AgentRunner(answers: AnswerStream(backend: resumingAgent(requests)))
    runner.answers.authoring = testAuthoring(extensions)
    // The conversation keeps the model it was built with.
    runner.answers.options = { _ in AgentOptions(model: "gpt-other") }
    let fix = ExtensionAuthoring.fix(
        "Test", id: "weather", failure: "It fails when Wicket runs it: no network")
    guard case .run(.runAgent, let text, let args, _, _) = fix else {
        Issue.record("not a Run Agent run")
        return
    }
    let detail = try #require(try await finalDetail(runner, text, args: args))
    #expect(detail.title == "Fix Test")
    let request = try #require(requests.last)
    #expect(request.resume == "thread-1")
    #expect(request.workingDirectory == built)
    #expect(
        request.options
            == AgentOptions(model: "gpt-x"))
    #expect(
        request.prompt.hasPrefix(
            "About my Wicket extension Test (`weather`, in \(try #require(extensions.discovered.first).folder.path)):"
                + "\n\nFind out why it fails and fix it.\n\nIt fails when Wicket runs it: no network"))
}

@MainActor @Test func fixWithAgentStartsAnewWithoutAConversationOrWhenAskedTo() async throws {
    let extensions = try await extensions([try plain("weather")], approved: ["weather"])
    let fix = ExtensionAuthoring.fix("Test", id: "weather", failure: "It fails.")
    guard case .run(.runAgent, let text, let args, _, _) = fix else { return }

    // None remembered: a new conversation, in the usual folder.
    let fresh = Requests()
    let runner = AgentRunner(answers: AnswerStream(backend: resumingAgent(fresh)))
    runner.answers.authoring = testAuthoring(extensions)
    _ = try await finalDetail(runner, text, args: args)
    #expect(fresh.all.count == 1 && fresh.last?.resume == nil)
    #expect(fresh.last?.prompt.hasPrefix("About my Wicket extension Test") == true)

    // Remembered but gone: the resume fails, and nothing starts anew by itself; the failure offers
    // a new conversation after Retry, which runs without the remembered one.
    let history = try #require(extensions.history)
    await history.remember(
        AnswerStream.Conversation(
            provider: .claude, folder: URL(filePath: "/tmp"),
            options: AgentProvider.claude.defaultOptions,
            session: "gone"),
        for: "weather")
    let retried = Requests()
    let again = AgentRunner(
        answers: AnswerStream(backend: resumingAgent(retried, resumes: false)))
    again.answers.authoring = runner.answers.authoring
    let failed = try #require(try await finalDetail(again, text, args: args))
    #expect(retried.all.map(\.resume) == ["gone"])
    #expect(failed.actions.map(\.title) == ["Retry", "Start New Conversation"])
    guard case .run(.runAgent, let freshText, let freshArgs, _, _) = failed.actions[1] else { return }
    #expect(freshArgs?["fresh"] == .bool(true) && freshArgs?["extension"] == .string("weather"))
    let detail = try #require(try await finalDetail(again, freshText, args: freshArgs))
    #expect(retried.all.map(\.resume) == ["gone", nil])
    #expect(detail.markdown == "Fixed it.")
}

@MainActor @Test func changeWithAgentWaitsForTheRequest() async throws {
    let change = ExtensionAuthoring.change(id: "weather")
    // No text: Run Agent's frame waits for what to change, and keeps the extension for the run.
    guard case .run(.runAgent, "", ["extension": .string("weather")], "Change with Agent", nil) = change
    else {
        Issue.record("not a waiting Run Agent run: \(change)")
        return
    }
}
