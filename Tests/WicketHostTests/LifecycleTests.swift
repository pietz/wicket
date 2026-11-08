import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The runs of installed extensions: each invocation runs exactly once, one extension's runs never
// overlap (cleanup included), and stopping, replacing or quitting ends what is running.

/// Extensions over the one folder `ext`, every valid revision active, writing into `data`.
@MainActor
private func extensions(_ ext: TestExtension, data: URL) async -> Extensions {
    let extensions = Extensions(
        directory: ext.folder.deletingLastPathComponent(), store: testStore(), approvals: testApprovals(),
        activate: Extensions.currentRevisions
    ) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    await extensions.load().value
    return extensions
}

private func temporaryData() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "wicket-tests/data-\(UUID().uuidString)")
}

private func log(in data: URL) throws -> [Substring] {
    try String(contentsOf: data.appending(path: "log"), encoding: .utf8).split(separator: "\n")
}

@MainActor
@Test func runsOfOneExtensionNeverOverlapAndEachRunsOnce() async throws {
    let script = """
        text=$(jq -r .text)
        echo "start $text" >> "$WICKET_DATA_DIR/log"
        sleep 0.05
        echo "end $text" >> "$WICKET_DATA_DIR/log"
        \(#"[ "$text" = bad ] && echo '{"error":{"message":"bad"}}' || echo '{"close":{}}'"#)
        """
    let data = temporaryData()
    let extensions = await extensions(try TestExtension(script: script), data: data)
    let go = try #require(extensions.commands.first).id
    try await withThrowingTaskGroup(of: Void.self) { group in
        for text in ["a", "bad", "c", "d"] {
            group.addTask { _ = try? await extensions.result(of: Invocation(command: go, text: text)) }
        }
        try await group.waitForAll()
    }
    let lines = try log(in: data)
    #expect(lines.count == 8)
    // Each start is followed by its own end: no run began while another was running.
    for pair in stride(from: 0, to: lines.count, by: 2) {
        #expect(lines[pair].dropFirst(6) == lines[pair + 1].dropFirst(4))
    }
    #expect(Set(lines.filter { $0.hasPrefix("start") }) == ["start a", "start bad", "start c", "start d"])
}

@MainActor
@Test func aSupersededLiveQueryEndsBeforeTheNextStarts() async throws {
    // A slow query logs its start, and its end when SIGTERM stops it; a fast one answers at once.
    let script = #"""
        text=$(jq -r .text)
        echo "start $text" >> "$WICKET_DATA_DIR/log"
        if [ "$text" = slow ]; then
          trap 'echo "end slow" >> "$WICKET_DATA_DIR/log"; exit 0' TERM
          /bin/sleep 30 & wait $!
        fi
        echo '{"close":{}}'
        """#
    let data = temporaryData()
    let extensions = await extensions(try TestExtension(script: script), data: data)
    let go = try #require(extensions.commands.first).id
    let slow = Task { try await extensions.result(of: Invocation(command: go, text: "slow")) }
    while (try? log(in: data)) == nil { try await Task.sleep(for: .milliseconds(10)) }
    slow.cancel()
    #expect(try await extensions.result(of: Invocation(command: go, text: "fast")) == .close(message: nil))
    await #expect(throws: CancellationError.self) { try await slow.value }
    #expect(try log(in: data) == ["start slow", "end slow", "start fast"])
}

@MainActor
@Test func replacingAnExtensionStopsItsRun() async throws {
    let ext = try TestExtension(
        script: "cat >/dev/null; echo start >> \"$WICKET_DATA_DIR/log\"; exec /bin/sleep 30")
    let data = temporaryData()
    let extensions = await extensions(ext, data: data)
    let go = try #require(extensions.commands.first).id
    let running = Task { try await extensions.result(of: Invocation(command: go)) }
    while (try? log(in: data)) == nil { try await Task.sleep(for: .milliseconds(10)) }
    try ext.change()
    await extensions.load(changed: [ext.folder.appending(path: "main.sh").path]).value
    await #expect(throws: HostError.stopped) { try await running.value }

    // A removed extension's commands are unknown.
    try FileManager.default.removeItem(at: ext.folder)
    await extensions.load().value
    await #expect(throws: HostError.unknownCommand) {
        try await extensions.result(of: Invocation(command: go))
    }
}

@MainActor
@Test func shuttingDownStopsEveryRunAndWhatItLeftRunning() async throws {
    // Leaves a child in its own session that holds stdout, then waits.
    let script = #"""
        cat >/dev/null
        /usr/bin/perl -e '
          use POSIX;
          POSIX::setsid();
          open(my $f, ">", "$ENV{WICKET_DATA_DIR}/pid.new"); print $f "$$"; close $f;
          rename("$ENV{WICKET_DATA_DIR}/pid.new", "$ENV{WICKET_DATA_DIR}/pid");
          sleep 30;
        ' &
        exec /bin/sleep 30
        """#
    let data = temporaryData()
    let extensions = await extensions(try TestExtension(script: script), data: data)
    let go = try #require(extensions.commands.first).id
    let running = Task { try await extensions.result(of: Invocation(command: go)) }
    let pid = data.appending(path: "pid")
    while !FileManager.default.fileExists(atPath: pid.path) { try await Task.sleep(for: .milliseconds(10)) }
    let child = try #require(pid_t(String(contentsOf: pid, encoding: .utf8)))

    let start = ContinuousClock.now
    await extensions.shutdown()
    #expect(!isRunning(child))
    #expect(ContinuousClock.now - start < .seconds(10))
    await #expect(throws: HostError.stopped) { try await running.value }
    // Nothing starts again.
    await #expect(throws: HostError.stopped) { try await extensions.result(of: Invocation(command: go)) }
}

@Test func agentThatClosesStdoutButLivesIsKilled() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/pid-\(UUID().uuidString)")
    let agent = try fakeAgent(.claude, "echo $$ > '\(pidFile.path)'\nexec 1>&-\nexec /bin/sleep 30")
    let request = AgentRequest(
        prompt: "test", workingDirectory: FileManager.default.temporaryDirectory,
        options: AgentProvider.claude.defaultOptions)
    let start = ContinuousClock.now
    var events: [AgentEvent] = []
    for await event in AgentProcess.run(
        agent.executable, arguments: [], in: request.workingDirectory,
        transcript: ClaudeTranscript(request: request),
        exitGrace: .milliseconds(200))
    {
        events.append(event)
    }
    #expect(events == [.error("claude stopped writing output")])
    // The hang this guards against lasts 30 s (the sleep); 10 s leaves room for a loaded machine.
    #expect(ContinuousClock.now - start < .seconds(10))
    let pid = try #require(
        pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var alive = true
    for _ in 0..<40 where alive {
        try await Task.sleep(for: .milliseconds(50))
        alive = kill(pid, 0) == 0
    }
    #expect(!alive)
}
