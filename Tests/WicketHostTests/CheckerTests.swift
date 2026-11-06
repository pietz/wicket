import Foundation
import Testing
import WicketCore

@testable import WicketHost

/// A throwaway extension folder: a manifest running `script` with /bin/sh, and an optional fixture.
struct TestExtension {
    let folder: URL

    init(
        id: String = "test", commands: String = #"[{"id":"go","title":"Go"}]"#, secrets: String = "[]",
        script: String, fixture: String? = nil
    ) throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/\(UUID().uuidString)/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
            {"protocol":1,"id":"\(id)","name":"Test","version":"1.0.0","run":["/bin/sh","main.sh"],
             "secrets":\(secrets),"commands":\(commands)}
            """
        try Data(manifest.utf8).write(to: folder.appending(path: "wicket.json"))
        try Data(script.utf8).write(to: folder.appending(path: "main.sh"))
        if let fixture { try Data(fixture.utf8).write(to: folder.appending(path: "session.jsonl")) }
    }

    var manifest: Manifest { get throws { try Manifest.load(from: folder) } }

    func session(_ configure: (inout SessionConfiguration) -> Void = { _ in }) throws -> ExtensionSession {
        try ExtensionSession(manifest: manifest, folder: folder, configuration: testConfiguration(configure))
    }
}

func testConfiguration(
    secrets: [String: String] = [:], _ configure: (inout SessionConfiguration) -> Void = { _ in }
) -> SessionConfiguration {
    var configuration = SessionConfiguration(
        dataDirectory: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/data-\(UUID().uuidString)"),
        version: "test"
    ) { secrets[$0] }
    configuration.requestTimeout = .seconds(1)
    configuration.exitGrace = .milliseconds(300)
    configuration.idleTimeout = nil
    configure(&configuration)
    return configuration
}

func send(_ id: Int, _ command: String = "go", text: String = "") -> String {
    #"{"send":{"jsonrpc":"2.0","id":\#(id),"method":"run","params":{"command":"\#(command)","text":"\#(text)","revision":\#(id)}}}"#
}

/// A persistent extension in shell: answers every request with `result`.
func answering(_ result: String) -> String {
    """
    while read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      case "$line" in *'"method":"run"'*) printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '\(result)';; esac
    done
    """
}

func checkOptions(_ configure: (inout CheckOptions) -> Void = { _ in }) -> CheckOptions {
    var options = CheckOptions(version: "test")
    options.requestTimeout = .seconds(1)
    options.exitGrace = .milliseconds(300)
    configure(&options)
    return options
}

func check(_ ext: TestExtension, _ configure: (inout CheckOptions) -> Void = { _ in }) async -> CheckReport {
    await Checker.check(ext.folder, options: checkOptions(configure))
}

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

/// Every sample passes the gate as it is, offline: github-prs answers from fixture/ when
/// WICKET_CHECK is set.
@Test(arguments: [
    "docs/examples/unicode", "docs/examples/week-number", "Extensions/github-prs", "Extensions/quit-apps",
    "Extensions/system-toggles",
])
func samplesPass(path: String) async {
    let report = await Checker.check(
        repository.appending(path: path), options: checkOptions { $0.requestTimeout = .seconds(30) })
    #expect(report.passed, "\(report.errors)")
}

@Test func badManifestFailsBeforeRunning() async throws {
    let ext = try TestExtension(
        commands: #"[{"id":"go","title":"Go","mode":"root","keyword":"g"}]"#, script: "")
    let report = await check(ext)
    #expect(report.errors == [#"wicket.json: commands[0].keyword: is not allowed for a root command"#])
}

@Test func strayStdoutFails() async throws {
    let ext = try TestExtension(script: "echo debugging\n" + answering(#"{"close":{}}"#), fixture: send(1))
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(errors.first?.contains(#"the extension wrote "debugging"; write logs to stderr"#) == true)
}

@Test func wrongIDFails() async throws {
    let script = #"read r; echo '{"jsonrpc":"2.0","id":7,"result":{"close":{}}}'"#
    let errors = await check(try TestExtension(script: script, fixture: send(1))).errors
    #expect(errors.contains { $0.contains("a response has id 7, which is not pending") })
    #expect(
        errors.contains { $0.contains("session.jsonl:1: request 1 (go): exited (status 0) before answering") }
    )
}

@Test func timeoutFails() async throws {
    let errors = await check(try TestExtension(script: "read r; sleep 5", fixture: send(1))).errors
    #expect(
        errors.contains { $0.contains("request 1 (go): no response within 1 s; the request was cancelled") })
    #expect(errors.contains { $0.contains("kept running 2 s after its stdin closed") })
}

@Test func crashFailsWithStderr() async throws {
    let script = "read r; echo 'Traceback: KeyError' >&2; exit 1"
    let errors = await check(try TestExtension(script: script, fixture: send(1))).errors
    #expect(errors.contains { $0.contains("request 1 (go): exited with status 1 before answering") })
    #expect(errors.contains { $0.contains("the last stderr lines were:\n    Traceback: KeyError") })
}

@Test func invalidResponseNamesThePath() async throws {
    let ext = try TestExtension(
        script: answering(#"{"list":{"items":[{"title":"a","actions":[{"copy":{"txt":"x"}}]}]}}"#),
        fixture: send(1))
    let errors = await check(ext).errors
    #expect(
        errors.contains { $0.contains(#"result.list.items[0].actions[0].copy.txt: unknown field "txt""#) })
}

@Test func expectMismatchNamesTheLineAndPath() async throws {
    let fixture = send(1) + "\n" + #"{"expect":{"id":1,"result":{"answer":{"title":"B"}}}}"#
    let ext = try TestExtension(script: answering(#"{"answer":{"title":"A"}}"#), fixture: fixture)
    #expect(
        await check(ext).errors == [
            #"session.jsonl:2: the response to id 1 doesn't match: result.answer.title: expected "B", got "A""#
        ])
}

@Test func undeclaredCommandsMustGetErrors() async throws {
    let ext = try TestExtension(script: answering(#"{"close":{}}"#), fixture: send(1, "nope"))
    #expect(
        await check(ext).errors.first?.contains(#"run for "nope", which wicket.json doesn't declare"#) == true
    )
}

@Test func modeRulesApply() async throws {
    let ext = try TestExtension(
        commands: #"[{"id":"go","title":"Go","mode":"root"}]"#,
        script: answering(#"{"detail":{"markdown":"x"}}"#),
        fixture: send(1))
    #expect(
        await check(ext).errors.first?.contains("result.detail: is not allowed for a root command") == true)
}

@Test func oneShotScriptsAreRestartedForEachRequest() async throws {
    // Answers one request, then exits cleanly: the other requests go to fresh processes.
    let script = #"""
        read -r line
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"answer":{"title":"%s"}}}\n' "$id" "$$"
        """#
    let session = try TestExtension(script: script).session()
    let replies = try await withThrowingTaskGroup(of: RunResult.self) { group in
        for _ in 0..<3 { group.addTask { try await session.run("go", text: "", retry: .safeToRepeat) } }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    let pids = Set(replies.compactMap { if case .answer(let item) = $0 { item.title } else { nil } })
    #expect(pids.count == 3)
}

@Test func environmentAndSecrets() async throws {
    let script = answering(#"{"answer":{"title":"'"$WICKET_PROTOCOL $WICKET_EXTENSION_ID $TOKEN $LANG"'"}}"#)
    let ext = try TestExtension(
        id: "env", secrets: #"[{"name":"TOKEN","title":"API token"}]"#, script: script)
    let session = ExtensionSession(
        manifest: try ext.manifest, folder: ext.folder,
        configuration: testConfiguration(secrets: ["TOKEN": "s3cret"]))
    guard case .answer(let item) = try await session.run("go", text: "", retry: .safeToRepeat) else {
        Issue.record("not an answer")
        return
    }
    #expect(item.title.hasPrefix("1 env s3cret "))
    #expect(item.title.hasSuffix(".UTF-8"))

    let missing = try ext.session()
    await #expect(throws: HostError.missingSecret(extensionID: "env", name: "TOKEN", title: "API token")) {
        try await missing.run("go", text: "", retry: .safeToRepeat)
    }
}

@Test func cancellingSendsCancelAndDropsTheLateAnswer() async throws {
    // Logs every line it receives to stderr, and answers after a delay.
    let script = #"""
        while read -r line; do
          echo "$line" >&2
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"run"'*) sleep 0.3; printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id";;
          esac
        done
        """#
    let session = try TestExtension(script: script).session()
    let task = Task { try await session.run("go", text: "", retry: .safeToRepeat) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await session.run("go", text: "", retry: .safeToRepeat) == .close(message: nil))
    let cancel = session.stderrTail.split(separator: "\n").first { $0.contains(#""method":"cancel""#) }
    #expect(cancel?.contains(#""params":{"id":1}"#) == true)
    #expect(await session.issues.isEmpty)
    #expect(await session.shutdown() == .exited(.status(0)))
}

@Test func idleProcessesAreReaped() async throws {
    let session = try TestExtension(script: answering(#"{"close":{}}"#)).session {
        $0.idleTimeout = .milliseconds(200)
    }
    _ = try await session.run("go", text: "", retry: .safeToRepeat)
    try await Task.sleep(for: .milliseconds(600))
    #expect(await session.shutdown() == .notRunning)
    // The next request starts a fresh process.
    #expect(try await session.run("go", text: "", retry: .safeToRepeat) == .close(message: nil))
}

@Test func overlongLinesStopTheProcess() async throws {
    let script = #"read r; head -c 1100000 /dev/zero | tr '\0' 'a'; echo; sleep 5"#
    let session = try TestExtension(script: script).session()
    await #expect(throws: HostError.lineTooLong) {
        try await session.run("go", text: "", retry: .safeToRepeat)
    }
}

@Test func missingProgramsAreNamed() async throws {
    let ext = try TestExtension(script: "")
    var manifest = try ext.manifest
    manifest.run = ["no-such-interpreter-wicket", "main.sh"]
    let session = ExtensionSession(manifest: manifest, folder: ext.folder, configuration: testConfiguration())
    await #expect {
        try await session.run("go", text: "", retry: .safeToRepeat)
    } throws: {
        "\($0)".contains("no-such-interpreter-wicket in run was not found on the login shell PATH")
    }
}
