import Foundation
import Testing
import WicketCore

@testable import WicketHost

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
    let pids = Set(
        replies.compactMap { if case .show(.answer(let item), _) = $0 { item.title } else { nil } })
    #expect(pids.count == 3)
}

@Test func environmentAndSecrets() async throws {
    let script = answering(#"{"answer":{"title":"'"$WICKET_PROTOCOL $WICKET_EXTENSION_ID $TOKEN $LANG"'"}}"#)
    let ext = try TestExtension(
        id: "env", secrets: #"[{"name":"TOKEN","title":"API token"}]"#, script: script)
    let session = ExtensionSession(
        manifest: try ext.manifest, folder: ext.folder,
        configuration: testConfiguration(secrets: ["TOKEN": "s3cret"]))
    guard case .show(.answer(let item), _) = try await session.run("go", text: "", retry: .safeToRepeat)
    else {
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
