import Darwin
import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

private func doFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-do-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return URL(filePath: try #require(CheckIsolation.realPath(folder.path)))
}

private func planJSON(_ script: String = "printf done", shell: String = "bash") throws -> String {
    String(
        decoding: try JSONEncoder().encode(
            DoPlan(explanation: "Make the requested change.", script: script, shell: shell)), as: UTF8.self)
}

private func doBackend(_ answer: String) -> AgentBackend {
    AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in
            #expect(request.mode == .plan)
            return AgentRun {
                $0.yield(.answer(answer, usage: nil))
                return .exited(.status(0))
            }
        })
}

private func collectDo(_ stream: AsyncThrowingStream<RunResult, any Error>) async throws -> [RunResult] {
    var results: [RunResult] = []
    for try await result in stream { results.append(result) }
    return results
}

private func doInvocation(_ action: Item.Action) throws -> Invocation {
    guard case .run(let command, let text, let args, _, _) = action else {
        throw BuildJob.Failure("Expected a run action")
    }
    return Invocation(command: command, text: text, args: args)
}

@Test func doPlanParsesJSONAndFencesWithoutChangingScript() throws {
    let script = "printf '%s\\n' 'hello'\n\n"
    let json = try planJSON(script)
    for text in [json, "```json\n\(json)\n```", "```\n\(json)\n```"] {
        #expect(DoPlan.parse(text)?.script == script)
    }
    for text in [
        "", "not JSON", "Before\n" + json, "```bash\necho hello\n```", "{}",
        try planJSON(""), try planJSON("echo x", shell: "sh"),
        try planJSON("echo safe\rdelete"), try planJSON("echo \u{202E}hidden"),
        try planJSON(String(repeating: "x", count: 65537)),
    ] {
        #expect(DoPlan.parse(text) == nil)
    }
}

@Test func doScriptFenceKeepsEmbeddedFencesVisible() {
    let script = "cat <<'EOF'\n```\n**not markdown**\n````\nEOF"
    let blocks = MarkdownBlock.parse(DoPlan.code(script, language: "bash"))
    #expect(blocks == [.code(script)])
}

@Test func doPlanningAdaptersAreReadOnlyAndOffline() throws {
    var codex = CodexTranscript(
        request: AgentRequest(prompt: "Plan", workingDirectory: URL(filePath: "/tmp"), mode: .plan))
    let thread = codex.receive(Data(#"{"id":2,"result":{"config":{}}}"#.utf8))
    let decoded = try JSONDecoder().decode(JSONValue.self, from: #require(thread.send.first))
    #expect(decoded["params"]?["sandbox"] == .string("read-only"))
    let turn = codex.receive(Data(#"{"id":3,"result":{"thread":{"id":"t"}}}"#.utf8))
    let policy = try JSONDecoder().decode(JSONValue.self, from: #require(turn.send.first))["params"]?[
        "sandboxPolicy"]
    #expect(policy?["type"] == .string("readOnly"))
    #expect(policy?["networkAccess"] == .bool(false))
    let args = CodexTranscript.arguments(for: .plan)
    #expect(!args.contains("features.shell_tool=false"))
    #expect(args.contains(#"web_search="disabled""#))
    let claude = ClaudeTranscript.arguments(for: .plan)
    #expect(claude[try #require(claude.firstIndex(of: "--tools")) + 1] == "Read,Glob,Grep")
    #expect(claude.contains("--restricted"))
    #expect(claude.contains("--safe-mode"))
    #expect(!claude.contains("acceptEdits"))
}

@MainActor @Test func doPlanDoesNothingUntilApprovedAndRunsExactlyTheDisplayedScript() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = "printf '%s' \"$BASH_EXECUTION_STRING\" > received\nprintf 'done\\n'"
    let job = DoJob(
        sentence: "remember the script", scope: folder, backend: doBackend(try planJSON(script)),
        provider: nil)
    await job.finished()
    #expect(job.phase == .ready)
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "received").path))
    let detail = DoRunner.detail(job)
    #expect(detail.actions.map(\.title) == ["Run", "Copy Script", "Cancel"])
    #expect(detail.actions.contains(.copy(text: script, title: "Copy Script")))
    #expect(MarkdownBlock.parse(detail.markdown).contains(.code(script)))
    #expect(throws: (any Error).self) { try job.execute(token: "forged") }
    try job.execute(token: job.token)
    #expect(throws: (any Error).self) { try job.execute(token: job.token) }
    await job.finished()
    #expect(job.phase == .succeeded, "\(job.phase), \(job.output)")
    #expect(try String(contentsOf: folder.appending(path: "received"), encoding: .utf8) == script)
    #expect(job.output == "done\n")
    #expect(DoRunner.detail(job).actions.first?.title == "Save as Command")
}

@Test(arguments: ["bash", "zsh"]) func doSandboxAllowsScopeAndTempButDeniesOutsideAndSymlinks(shell: String)
    async throws
{
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let scope = folder.appending(path: "scope \"quoted\"")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: scope.appending(path: "escape"), withDestinationURL: folder)
    let script = """
        printf inside > inside
        printf temporary > "$TMPDIR/allowed"
        if (printf no > ../outside) 2>/dev/null; then exit 2; fi
        if (printf no > escape/escaped) 2>/dev/null; then exit 3; fi
        printf allowed
        """
    let run = DoScript.run(DoPlan(explanation: "Test", script: script, shell: shell), scope: scope)
    var events: [AgentEvent] = []
    for await event in run { events.append(event) }
    #expect(events.contains { if case .answer = $0 { true } else { false } }, "\(events)")
    #expect(try String(contentsOf: scope.appending(path: "inside"), encoding: .utf8) == "inside")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "outside").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "escaped").path))
}

@Test func doSandboxDeniesNetwork() async throws {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let listening = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(socket, $0, length) == 0 && listen(socket, 8) == 0 && getsockname(socket, $0, &length) == 0
        }
    }
    #expect(listening)
    let port = UInt16(bigEndian: address.sin_port)
    let control = await AgentProcess.output(
        of: URL(filePath: "/usr/bin/nc"), arguments: ["-z", "-w", "2", "127.0.0.1", String(port)])
    #expect(control?.status == 0)
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = "if /usr/bin/nc -z -w 2 127.0.0.1 \(port); then exit 4; fi; printf blocked"
    let run = DoScript.run(DoPlan(explanation: "Test", script: script, shell: "bash"), scope: folder)
    var succeeded = false
    for await event in run { if case .answer = event { succeeded = true } }
    #expect(succeeded)
}

@MainActor @Test func malformedDoAnswerAndCancelledPlanHaveNoRunAction() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let malformed = DoJob(
        sentence: "test", scope: folder, backend: doBackend("unstructured answer"), provider: nil)
    await malformed.finished()
    #expect(malformed.phase == .unparsed)
    #expect(DoRunner.detail(malformed).markdown.contains("unstructured answer"))
    #expect(!DoRunner.detail(malformed).actions.contains { $0.title == "Run" })
    let job = DoJob(sentence: "test", scope: folder, backend: doBackend(try planJSON()), provider: nil)
    await job.finished()
    job.stop()
    #expect(throws: (any Error).self) { try job.execute(token: job.token) }
    await job.cancel()
    #expect(job.phase == .cancelled)
}

@MainActor @Test func doStopCancelsScriptAndFailureCannotBeKept() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let job = DoJob(
        sentence: "wait", scope: folder,
        backend: doBackend(try planJSON("echo started; sleep 30; echo finished")), provider: nil)
    await job.finished()
    try job.execute(token: job.token)
    let deadline = ContinuousClock.now + .seconds(5)
    while job.output.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(job.output.contains("started"))
    let start = ContinuousClock.now
    await job.cancel()
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(job.phase == .cancelled)
    #expect(!job.output.contains("finished"))
    let failed = DoJob(
        sentence: "fail", scope: folder, backend: doBackend(try planJSON("echo failed; exit 7")),
        provider: nil)
    await failed.finished()
    try failed.execute(token: failed.token)
    await failed.finished()
    guard case .failed(let message) = failed.phase else {
        Issue.record("expected failure")
        return
    }
    #expect(message.contains("status 7"))
    #expect(!DoRunner.detail(failed).actions.contains { $0.title == "Save as Command" })
}

@MainActor @Test func doFolderPickerKeepAndShutdownUseTheExistingBuildFlow() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let requests = Mutex<[AgentRequest]>([])
    let buildBackend = AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in
            requests.withLock { $0.append(request) }
            return AgentRun {
                $0.yield(.error("test stops before writing an extension"))
                return .exited(.status(0))
            }
        })
    let builds = BuildJobs(
        backend: buildBackend, staging: folder.appending(path: "staging"), guide: { "The guide" })
    let runner = DoRunner(builds: builds, backend: doBackend(try planJSON("printf kept")), home: folder)
    let input = Invocation(command: .doAction, text: "print kept")
    let picker = try await collectDo(runner.run(input, retry: .never))
    guard case .show(.list(let items))? = picker.last else {
        Issue.record("expected folder picker")
        return
    }
    #expect(items.map(\.title) == ["Desktop", "Downloads", "Documents", "Home"])
    #expect(items.last?.subtitle?.contains("Warning") == true)
    let select = try doInvocation(#require(items.last?.actions.first))
    _ = try await collectDo(runner.run(select, retry: .never))
    let job = try #require(runner.current)
    #expect(job.scope == folder)
    let execute = try doInvocation(#require(DoRunner.detail(job).actions.first))
    _ = try await collectDo(runner.run(execute, retry: .never))
    #expect(job.phase == .succeeded)
    let keep = try doInvocation(#require(DoRunner.detail(job).actions.first))
    _ = try await collectDo(runner.run(keep, retry: .never))
    let request = try #require(requests.withLock { $0.first })
    #expect(request.mode == .build)
    #expect(request.prompt.contains("print kept"))
    #expect(request.prompt.contains(folder.path))
    #expect(request.prompt.contains("printf kept"))
    #expect(request.prompt.contains("canned data"))
    #expect(request.prompt.contains("<guide>\nThe guide\n</guide>"))
    #expect(builds.current?.promptContext == job.plan?.buildContext(scope: folder))
    await runner.shutdown()
    await builds.shutdown()
    await #expect(throws: CancellationError.self) { try await collectDo(runner.run(input, retry: .never)) }
}

@MainActor @Test func doExplanationCannotHideTheReviewedScript() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let plan = DoPlan(
        explanation: "<!--\n```\n[hidden](https://example.com)", script: "echo visible", shell: "bash")
    let answer = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    let job = DoJob(sentence: "test", scope: folder, backend: doBackend(answer), provider: nil)
    await job.finished()
    #expect(MarkdownBlock.parse(DoRunner.detail(job).markdown).contains(.code(plan.script)))
}

@MainActor @Test func doDetachedFrameKeepsRunningAndAStaleApprovalCannotRunANewPlan() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let builds = BuildJobs(staging: folder.appending(path: "builds"), guide: { "guide" })
    let runner = DoRunner(
        builds: builds, backend: doBackend(try planJSON("echo started; sleep 0.2; echo done")), home: folder)
    let selection = Invocation(
        command: .doAction, text: "test", args: ["scope": .string("Home"), "new": .bool(true)])
    _ = try await collectDo(runner.run(selection, retry: .never))
    let first = try #require(runner.current)
    let approved = try doInvocation(#require(DoRunner.detail(first).actions.first))
    let stream = runner.run(approved, retry: .never)
    let observer = Task { try await collectDo(stream) }
    observer.cancel()  // The frame disappears, but the job keeps its task.
    _ = try? await observer.value
    _ = try await collectDo(
        runner.run(Invocation(command: .doAction, text: "another request"), retry: .never))
    #expect(runner.current === first)
    await first.finished()
    #expect(first.phase == .succeeded)
    #expect(first.output.contains("done"))
    _ = try await collectDo(runner.run(approved, retry: .never))
    #expect(first.output.components(separatedBy: "started").count == 2)  // Reopen, never rerun.
    _ = try await collectDo(runner.run(selection, retry: .never))
    let second = try #require(runner.current)
    #expect(second !== first)
    await #expect(throws: (any Error).self) { try await collectDo(runner.run(approved, retry: .never)) }
    #expect(second.phase == .ready)
    await runner.shutdown()
    await builds.shutdown()
}

@MainActor @Test func doOffersTheFinderSelectionsFolderFirstAndPlansThere() async throws {
    let folder = try doFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let shots = folder.appending(path: "Shots", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    let file = shots.appending(path: "a.png")
    try Data().write(to: file)
    let builds = BuildJobs(
        backend: doBackend(try planJSON("true")), staging: folder.appending(path: "staging"), guide: { "" })
    let runner = DoRunner(builds: builds, backend: doBackend(try planJSON("true")), home: folder)
    let context = try #require(SummonContext(app: "Finder", files: [file]))
    let input = Invocation(command: .doAction, text: "rename them", context: context)
    let picker = try await collectDo(runner.run(input, retry: .never))
    guard case .show(.list(let items))? = picker.last else {
        Issue.record("expected folder picker")
        return
    }
    #expect(items.map(\.title) == ["Shots", "Desktop", "Downloads", "Documents", "Home"])
    // The action carries the folder: the context is gone by the time it runs.
    let select = try doInvocation(#require(items.first?.actions.first))
    #expect(select.context == nil)
    _ = try await collectDo(runner.run(select, retry: .never))
    let job = try #require(runner.current)
    #expect(job.scope.path == CheckIsolation.realPath(shots.path))
    await runner.shutdown()
    await builds.shutdown()
}
