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
    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    for found in extensions.discovered where approved.contains(found.id) {
        try await extensions.approve(try #require(found.sealed).revision)
    }
    return extensions
}

private func plain(_ id: String) throws -> TestExtension {
    try TestExtension(id: id, script: answering(#"{"answer":{"title":"hi"}}"#))
}

/// The requests an agent was sent.
private final class Requests: Sendable {
    private let all = Mutex<[AgentRequest]>([])
    func append(_ request: AgentRequest) { all.withLock { $0.append(request) } }
    var first: AgentRequest? { all.withLock { $0.first } }
    var last: AgentRequest? { all.withLock { $0.last } }
}

/// An agent that runs `body` (writing files, say) and then sends `events`, by default an answer.
private func agent(
    _ requests: Requests,
    events sent: [AgentEvent] = [.answer("Made it; review and enable it in Wicket.", usage: nil)],
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
        if case .show(.detail(let detail)) = result { last = detail }
    }
    return last
}

@MainActor @Test func actingRunsAreToldWicketsCommandsAndWhereExtensionsGo() async throws {
    let extensions = try await extensions([])
    let commands = [
        RegisteredCommand(id: .builtin("settings"), title: "Wicket Settings", icon: .symbol(name: "gear")),
        RegisteredCommand(
            id: .extension("weather", "today"), title: "Weather", icon: .symbol(name: "sun.max"), keyword: "w"
        ),
        RegisteredCommand(
            id: .builtin("hidden"), title: "Hidden Thing", icon: .symbol(name: "eye"), isListed: false),
    ]
    let guide = URL(filePath: "/Applications/Wicket.app/Contents/Resources/extensions.md")
    let authoring = ExtensionAuthoring(
        extensions: extensions, commands: { commands }, guide: guide, tool: nil)
    let text = authoring.instructions()
    #expect(text.contains("- Wicket Settings\n- Weather, keyword `w` (extension `weather`)\n"))
    #expect(!text.contains("Hidden Thing"))
    #expect(text.contains(extensions.directory.path))
    #expect(text.contains("read the authoring guide at \(guide.path)"))
    #expect(text.contains("ready to review and enable"))
    #expect(!text.contains("Wicket's check is"))
    let without = ExtensionAuthoring(
        extensions: extensions, commands: { [] }, guide: nil,
        tool: URL(filePath: "/W.app/Contents/Helpers/wicket")
    ).instructions()
    #expect(without.contains("Follow an existing extension in that folder"))
    #expect(without.contains("Wicket's check is `/W.app/Contents/Helpers/wicket check <folder>`."))

    // The instructions go to Codex after Wicket's own, as its developer instructions.
    var transcript = CodexTranscript(
        request: AgentRequest(
            prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .acting, instructions: text))
    let start = transcript.start()
    guard case .object(let thread)? = try? JSONDecoder().decode(JSONValue.self, from: start.send[2]) else {
        Issue.record("no thread/start")
        return
    }
    #expect(thread["params"]?["developerInstructions"] == .string(Agent.actInstructions + "\n\n" + text))
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
            }, interval: .zero, provider: { .codex }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    runner.saveCommand = { _ in Item.Action.copy(text: "", title: "Save as Command") }

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
    #expect(request.configuration != nil)
    #expect(request.instructions?.contains(directory.path) == true)
}

@MainActor @Test func anAnswerThatChangedNoExtensionOffersSaveAsBefore() async throws {
    let extensions = try await extensions([try plain("enabled")], approved: ["enabled"])
    let requests = Requests()
    let runner = AgentRunner(
        answers: AnswerStream(backend: agent(requests) {}, interval: .zero, provider: { .codex }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    runner.saveCommand = { _ in Item.Action.copy(text: "", title: "Save as Command") }
    let detail = try #require(try await finalDetail(runner, "what can you do?"))
    #expect(detail.actions.compactMap { $0.title } == ["Copy Answer", "Paste Answer", "Save as Command"])
}

@MainActor @Test func aRunThatFailedAfterWritingAnExtensionStillOffersItsReview() async throws {
    let extensions = try await extensions([])
    let directory = extensions.directory
    let made = try plain("weather")
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests(), events: [.text("Writing it"), .error("Claude Code was interrupted")]) {
                try FileManager.default.copyItem(at: made.folder, to: directory.appending(path: "weather"))
            }, interval: .zero, provider: { .claude }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    let detail = try #require(try await finalDetail(runner, "build a weather command"))
    #expect(detail.actions.compactMap { $0.title } == ["Review and Enable Test", "Retry", "Copy Answer"])

    // With nothing streamed, the failure page offers it too.
    let silent = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests(), events: [.error("stopped")]) {
                let script = directory.appending(path: "weather/main.sh")
                try (String(contentsOf: script, encoding: .utf8) + "\n# v2\n").write(
                    to: script, atomically: false, encoding: .utf8)
            }, interval: .zero, provider: { .claude }))
    silent.answers.authoring = runner.answers.authoring
    let failure = try #require(try await finalDetail(silent, "change it"))
    #expect(failure.actions.compactMap { $0.title } == ["Review and Enable Test", "Retry"])
}

@MainActor @Test func onlyAPureAnswerOffersSaveAsCommand() async throws {
    let extensions = try await extensions([])
    let runner = AgentRunner(
        answers: AnswerStream(
            backend: agent(
                Requests(), events: [.activity("Ran ls"), .acted, .answer("Three files.", usage: nil)]
            ) {}, interval: .zero, provider: { .claude }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    runner.saveCommand = { _ in Item.Action.copy(text: "", title: "Save as Command") }
    let acted = try #require(try await finalDetail(runner, "how many files are here?"))
    #expect(acted.actions.compactMap { $0.title } == ["Copy Answer", "Paste Answer"])

    // Reading isn't acting.
    let reader = AgentRunner(
        answers: AnswerStream(
            backend: agent(Requests(), events: [.activity("Read a.txt"), .answer("It says hi.", usage: nil)])
            {},
            interval: .zero, provider: { .claude }))
    reader.answers.authoring = runner.answers.authoring
    reader.saveCommand = runner.saveCommand
    let read = try #require(try await finalDetail(reader, "what does a.txt say?"))
    #expect(read.actions.compactMap { $0.title } == ["Copy Answer", "Paste Answer", "Save as Command"])
}

@MainActor @Test func aRunCanNameItsFrame() async throws {
    let runner = AgentRunner(
        answers: AnswerStream(backend: agent(Requests()) {}, interval: .zero, provider: { .claude }))
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
        if case .show(.detail(let detail)) = result { last = detail }
    }
    let detail = try #require(last)
    #expect(!detail.actions.contains { $0.title == "Enable" })
    let fix = try #require(detail.actions.first { $0.title == "Fix with Agent" })
    guard case .run(.runAgent, let text, let args, _, nil) = fix else {
        Issue.record("not a Run Agent run: \(fix)")
        return
    }
    // The frame is titled by the extension; the whole failure goes to the agent.
    #expect(args == ["title": .string("Fix Test")])
    #expect(text.hasPrefix("Fix my Wicket extension Test in /"))
    #expect(text.contains("/broken.\n\nIt failed Wicket's check:"))
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
    let guide = URL(filePath: #filePath).deletingLastPathComponent().appending(
        path: "../../docs/extensions.md"
    )
    .standardizedFileURL
    let runner = AgentRunner(answers: AnswerStream(provider: { .codex }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: guide)
    var last: Detail?
    for try await result in runner.run(
        Invocation(
            command: .runAgent, text: "Build an extension that shows the current ISO week number in Wicket.",
            context: SummonContext(app: "Finder", files: [root])), retry: .never)
    {
        if case .show(.detail(let detail)) = result { last = detail }
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
        if case .show(.detail(let detail)) = result { page = detail }
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
    let guide = URL(filePath: #filePath).deletingLastPathComponent().appending(
        path: "../../docs/extensions.md"
    )
    .standardizedFileURL
    let runner = AgentRunner(answers: AnswerStream(provider: { .claude }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: guide)
    var last: Detail?
    for try await result in runner.run(
        Invocation(
            command: .runAgent, text: "Build an extension that shows the current ISO week number in Wicket.",
            context: SummonContext(app: "Finder", files: [root])), retry: .never)
    {
        if case .show(.detail(let detail)) = result { last = detail }
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
        if case .show(.detail(let detail)) = result { page = detail }
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
            }, interval: .zero, provider: { .codex }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    let detail = try #require(try await finalDetail(runner, "fix it"))
    #expect(detail.actions.first?.title == "Review and Enable broken")
}

@MainActor @Test func aChangeMadeBeforeTheRunIsNotTheRunsWork() async throws {
    let extensions = try await extensions([])
    // Written before the run, before any watcher event arrives.
    try FileManager.default.copyItem(
        at: try plain("earlier").folder, to: extensions.directory.appending(path: "earlier"))
    let runner = AgentRunner(
        answers: AnswerStream(backend: agent(Requests()) {}, interval: .zero, provider: { .codex }))
    runner.answers.authoring = ExtensionAuthoring(extensions: extensions, commands: { [] }, guide: nil)
    let detail = try #require(try await finalDetail(runner, "what's the time?"))
    #expect(!detail.actions.contains { $0.title?.hasPrefix("Review") == true })
}

@MainActor @Test func longTitlesAreClippedInTheInstructions() async throws {
    let extensions = try await extensions([])
    let long = String(repeating: "x", count: 5000)
    let commands = [
        RegisteredCommand(id: .builtin("odd"), title: long, icon: .symbol(name: "gear"), keyword: long)
    ]
    let text = ExtensionAuthoring(extensions: extensions, commands: { commands }, guide: nil).instructions()
    #expect(text.count < 1500)
}
