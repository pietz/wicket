import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// Process lifecycle: every way of giving up on a process ends in SIGKILL, actions are never resent,
// and a replaced extension's process is gone before its successor starts.

@Test func overlongLinesEscalateToSIGKILL() async throws {
    // Ignores SIGTERM (the disposition survives exec) and stdin closing.
    let script = #"trap '' TERM; read r; head -c 1100000 /dev/zero | tr '\0' 'a'; echo; exec /bin/sleep 5"#
    let session = try TestExtension(script: script).session()
    let start = ContinuousClock.now
    await #expect(throws: HostError.lineTooLong) { try await session.run("go", text: "", kind: .query) }
    #expect(await session.shutdown() == .killed)
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test func actionsAreNeverResent() async throws {
    // Reads two requests, logs them to stderr, answers the first and exits cleanly.
    let script = #"""
        read -r a; echo "$a" >&2
        read -r b; echo "$b" >&2
        id=$(printf '%s' "$a" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id"
        """#
    let session = try TestExtension(script: script).session()
    let first = try await session.submit(
        .number(1), RunParams(command: "go", text: "", revision: 1), kind: .query)
    let action = try await session.submit(
        .number(2), RunParams(command: "go", text: "", revision: 2, args: ["id": .number(7)]), kind: .action)
    #expect(try await first.value.outcome.get() == .close(message: nil))
    await #expect(throws: HostError.actionInterrupted) { try await action.value }
    let written = session.stderrTail.split(separator: "\n").filter { $0.contains(#""id":2"#) }
    #expect(written.count == 1)

    // A query in the same position would be resent: oneShotScriptsAreRestartedForEachRequest.
}

@Test func stoppedSessionsRefuseRequests() async throws {
    let session = try TestExtension(script: answering(#"{"close":{}}"#)).session()
    _ = try await session.run("go", text: "", kind: .query)
    await session.stop()
    await #expect(throws: HostError.stopped) { try await session.run("go", text: "", kind: .query) }
    #expect(await session.shutdown() == .notRunning)
}

@MainActor
@Test func replacedExtensionsShutDownBeforeTheirSuccessorStarts() async throws {
    // Logs its start, and its end 0.1 s after stdin closes (within the 0.3 s test grace).
    let script = """
        echo start >> "$WICKET_DATA_DIR/log"
        \(answering(#"{"close":{}}"#))
        sleep 0.1
        echo end >> "$WICKET_DATA_DIR/log"
        """
    let ext = try TestExtension(script: script)
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent()) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    extensions.load()
    let command = Invocation(command: try #require(extensions.commands.first).id)
    #expect(try await extensions.run(command, kind: .query) == .close(message: nil))

    extensions.load(changed: [ext.folder.appending(path: "main.sh").path])
    #expect(try await extensions.run(command, kind: .query) == .close(message: nil))
    let log = try String(contentsOf: data.appending(path: "log"), encoding: .utf8)
    #expect(log.split(separator: "\n") == ["start", "end", "start"])

    // A removed extension's commands are unknown, and its session is stopped.
    try FileManager.default.removeItem(at: ext.folder)
    extensions.load()
    await #expect(throws: HostError.unknownCommand) { try await extensions.run(command, kind: .query) }
}

@Test func agentThatClosesStdoutButLivesIsKilled() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/pid-\(UUID().uuidString)")
    let agent = try fakeAgent(.claude, "echo $$ > '\(pidFile.path)'\nexec 1>&-\nexec /bin/sleep 30")
    let request = AgentRequest(
        prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
    let start = ContinuousClock.now
    var events: [AgentEvent] = []
    for await event in AgentProcess.run(
        agent.executable, arguments: [], request: request, transcript: ClaudeTranscript(request: request),
        exitGrace: .milliseconds(200))
    {
        events.append(event)
    }
    #expect(events == [.error("claude stopped writing output")])
    #expect(ContinuousClock.now - start < .seconds(3))
    let pid = try #require(
        pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var alive = true
    for _ in 0..<40 where alive {
        try await Task.sleep(for: .milliseconds(50))
        alive = kill(pid, 0) == 0
    }
    #expect(!alive)
}
