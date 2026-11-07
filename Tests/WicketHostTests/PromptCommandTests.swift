import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

private final class PromptBackend: Sendable {
    let requests = Mutex<[AgentRequest]>([])
    let events: [AgentEvent]

    init(events: [AgentEvent] = [.text("Partial"), .answer("Fertig", usage: nil)]) {
        self.events = events
    }

    var backend: AgentBackend {
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) },
            run: { _, request in
                self.requests.withLock { $0.append(request) }
                return AgentRun { output in
                    for event in self.events { output.yield(event) }
                    return .notRunning
                }
            })
    }
}

@MainActor
private func details(_ runner: any CommandRunner, _ invocation: Invocation) async throws -> [Detail] {
    var details: [Detail] = []
    for try await result in runner.run(invocation, retry: .never) {
        if case .show(.detail(let detail)) = result { details.append(detail) }
    }
    return details
}

@MainActor
private struct Prompts {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/prompts-\(UUID().uuidString)")
    let backend = PromptBackend()
    let extensions: Extensions
    let reviews: ExtensionsRunner
    let ask: AskAIRunner
    let runner: PromptCommandRunner

    init() {
        extensions = Extensions(directory: folder, store: testStore(), approvals: testApprovals())
        reviews = ExtensionsRunner(extensions: extensions, jobs: nil)
        ask = AskAIRunner(backend: backend.backend, interval: .zero, provider: { .codex })
        runner = PromptCommandRunner(answers: ask, extensions: extensions, reviews: reviews)
        extensions.promptRunner = runner
        ask.saveCommand = { [weak runner] in runner?.offer($0) }
    }

    func clean() async {
        await extensions.shutdown()
        extensions.store.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor @Test func promptCheckerNeedsNoFixtureSandboxOrProgram() async throws {
    let h = Prompts()
    let folder = try PromptCommandRunner.write(
        Invocation(command: .builtin("ask-ai"), text: "Hello"), into: h.folder)
    // Even a declared executable must never start when every command is a prompt.
    let manifestURL = folder.appending(path: Manifest.fileName)
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    object["run"] = ["/no/such/executable"]
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    let report = await Checker.check(
        folder: folder, options: checkOptions { $0.sandboxExecutable = URL(filePath: "/no/sandbox") })
    #expect(report.passed)
    #expect(report.lines.contains { $0.text.contains("no process") })
    #expect(h.backend.requests.withLock { $0.isEmpty })
    await h.clean()
}

@MainActor @Test func saveFinishedAnswerWritesValidPrivateTemplateThenReviewsWithoutEnabling() async throws {
    let h = Prompts()
    let selection = "Private selected material"
    let context = try #require(SummonContext(app: "Mail", text: selection))
    let invocation = Invocation(
        command: .builtin("ask-ai"), text: "Translate \(selection) to German", context: context)
    let shown = try await details(h.ask, invocation)
    #expect(shown.dropLast().allSatisfy { !$0.actions.contains { $0.title == "Save as Command" } })
    let save = try #require(shown.last?.actions.last)
    #expect(save.title == "Save as Command")
    guard case .run(let command, let text, let args, _, let revision) = save else {
        Issue.record("Missing save action")
        return
    }
    let review = try await details(
        h.runner, Invocation(command: command, text: text, args: args, revision: revision))
    #expect(review.last?.markdown.contains("Uses your AI provider") == true)
    #expect(review.last?.markdown.contains("{selection}") == true)
    #expect(review.last?.actions.first?.title == "Enable")
    let found = try #require(h.extensions.discovered.first)
    let manifest = try Manifest.load(from: found.folder)
    #expect(manifest.commands.first?.prompt == "Translate {selection} to German")
    #expect(manifest.commands.first?.keyword == "german")
    let bytes = try String(contentsOf: found.folder.appending(path: Manifest.fileName), encoding: .utf8)
    #expect(!bytes.contains(selection))
    #expect(!bytes.contains("Fertig"))
    #expect(h.extensions.commands.isEmpty)
    #expect(h.extensions.approvals.all.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: found.folder.path) == [Manifest.fileName])
    // Enable still needs the review token, exactly as a program extension does.
    let enable = try #require(review.last?.actions.first)
    guard case .run(let enableID, _, let enableArgs, _, _) = enable else { return }
    _ = try await details(h.reviews, Invocation(command: enableID, args: enableArgs))
    #expect(h.extensions.commands.count == 1)
    await h.clean()
}

@MainActor @Test func approvedPromptsStreamThroughExtensionsAndRefuseStaleOrUnapprovedRuns() async throws {
    let h = Prompts()
    let firstContext = try #require(SummonContext(app: "Mail", text: "old selection"))
    let folder = try PromptCommandRunner.write(
        Invocation(command: .builtin("ask-ai"), text: "Translate this to German", context: firstContext),
        into: h.folder)
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    let command = CommandID.extension(sealed.manifest.id, "ask")
    await #expect(throws: HostError.notApproved) {
        try await details(h.extensions, Invocation(command: command))
    }
    #expect(h.backend.requests.withLock { $0.isEmpty })
    try await h.extensions.approve(sealed.revision)
    let context = try #require(SummonContext(app: "Notes", text: "new selection {text}"))
    let invocation = Invocation(command: command, text: "formal", revision: sealed.revision, context: context)
    let shown = try await details(h.extensions, invocation)
    #expect(shown.last?.markdown == "Fertig")
    #expect(shown.last?.title == "Translate this to German")
    #expect(
        shown.last?.actions == [
            .copy(text: "Fertig", title: "Copy Answer"), .paste(text: "Fertig", title: "Paste Answer"),
        ])
    #expect(
        h.backend.requests.withLock { $0.last?.prompt } == "Translate this to German\n\nnew selection {text}")
    #expect(h.backend.requests.withLock { $0.last?.mode } == .answer)
    #expect(h.extensions.commands.first?.usesContext == true)
    // Changing the authoring folder does not change the approved template.
    let url = folder.appending(path: Manifest.fileName)
    let changed = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
        of: "German", with: "French")
    try changed.write(to: url, atomically: true, encoding: .utf8)
    await h.extensions.load(changed: [url.path]).value
    _ = try await details(h.extensions, invocation)
    #expect(h.backend.requests.withLock { $0.last?.prompt.contains("German") } == true)
    let next = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(next.revision)
    await #expect(throws: HostError.extensionChanged) { try await details(h.extensions, invocation) }
    try await h.extensions.revoke(sealed.manifest.id)
    await #expect(throws: HostError.notApproved) {
        try await details(h.extensions, Invocation(command: command))
    }
    await h.clean()
}

@MainActor @Test func saveUsesSelectionPlaceholderForThisAndNeverOverwrites() async throws {
    let h = Prompts()
    let context = try #require(SummonContext(app: "Mail", text: "sensitive"))
    let invocation = Invocation(command: .builtin("ask-ai"), text: "Fix grammar in this", context: context)
    let first = try PromptCommandRunner.write(invocation, into: h.folder)
    let second = try PromptCommandRunner.write(invocation, into: h.folder)
    #expect(first != second)
    #expect(try Manifest.load(from: first).commands.first?.prompt == "Fix grammar in this\n\n{selection}")
    #expect(try Manifest.load(from: second).commands.first?.prompt == "Fix grammar in this\n\n{selection}")
    await #expect(throws: (any Error).self) {
        try await details(
            h.runner, Invocation(command: .savePromptCommand, args: ["save": .string("forged")]))
    }
    await h.clean()
}

@MainActor @Test func mixedExtensionsNeverSendPromptCommandsToTheirProgram() async throws {
    let ext = try TestExtension(
        commands: #"[{"id":"ai","title":"AI","prompt":"Hello"},{"id":"go","title":"Go"}]"#,
        script: "exit 99", fixture: send(1, "ai"))
    let session = try ext.session()
    await #expect(throws: Refusal.self) {
        try await session.run("ai", text: "", retry: .never)
    }
    let report = await check(ext)
    #expect(!report.passed)
    #expect(report.errors.contains { $0.contains("fixtures may only run program commands") })
    await session.stop()
    try? FileManager.default.removeItem(at: ext.folder)
}

@MainActor @Test func failedAnswersNeverOfferSaveAndPromptRetryKeepsItsInvocation() async throws {
    let h = Prompts()
    let backend = PromptBackend(events: [.text("Half"), .error("offline")])
    let ask = AskAIRunner(backend: backend.backend, interval: .zero, provider: { .codex })
    ask.saveCommand = { h.runner.offer($0) }
    let shown = try await details(ask, Invocation(command: .builtin("ask-ai"), text: "  question  "))
    #expect(shown.allSatisfy { !$0.actions.contains { $0.title == "Save as Command" } })
    #expect(shown.last?.actions.first == .run(command: .builtin("ask-ai"), text: "question", title: "Retry"))
    let folder = try PromptCommandRunner.write(
        Invocation(command: .builtin("ask-ai"), text: "Hello {text}"), into: h.folder)
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    let prompts = PromptCommandRunner(answers: ask, extensions: h.extensions, reviews: h.reviews)
    let invocation = Invocation(
        command: .extension(folder.lastPathComponent, "ask"), text: "typed", args: ["extra": .bool(true)],
        revision: sealed.revision)
    let failed = try await details(prompts, invocation)
    #expect(failed.last?.markdown.contains("incomplete") == true)
    #expect(
        failed.last?.actions == [
            .run(
                command: invocation.command, text: "typed", args: invocation.args, title: "Retry",
                revision: sealed.revision), .copy(text: "Half", title: "Copy Answer"),
        ])
    await prompts.shutdown()
    await #expect(throws: CancellationError.self) {
        try await details(prompts, Invocation(command: .savePromptCommand))
    }
    await h.clean()
}

@MainActor @Test func promptKeywordTypingDoesNotAskTheProvider() async throws {
    let h = Prompts()
    let context = try #require(SummonContext(app: "Notes", text: "Selected"))
    _ = try PromptCommandRunner.write(
        Invocation(command: .builtin("ask-ai"), text: "Translate this to German", context: context),
        into: h.folder)
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    let registry = CommandRegistry()
    registry.setExtensionCommands(h.extensions.commands)
    let session = PaletteSession(sources: [], runner: h.extensions, registry: registry)
    session.query = "german "
    #expect(session.frames.count == 2)
    #expect(!session.top.isLoading)
    session.query = "formal"
    #expect(h.backend.requests.withLock { $0.isEmpty })
    #expect(
        session.top.target?.actions.first
            == .run(
                command: .extension(sealed.manifest.id, "ask"), text: "formal",
                title: "Translate this to German", revision: sealed.revision))
    session.reset()
    await h.clean()
}
