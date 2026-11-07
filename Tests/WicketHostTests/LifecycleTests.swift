import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// Process lifecycle: every way of giving up on a process ends in SIGKILL, actions are never resent,
// and a replaced extension's process, and everything it left running, is gone before its successor
// starts.

@Test func overlongLinesEscalateToSIGKILL() async throws {
    // Ignores SIGTERM (the disposition survives exec) and stdin closing.
    let script = #"trap '' TERM; read r; head -c 1100000 /dev/zero | tr '\0' 'a'; echo; exec /bin/sleep 5"#
    let session = try TestExtension(script: script).session()
    let start = ContinuousClock.now
    await #expect(throws: HostError.lineTooLong) {
        try await session.run("go", text: "", retry: .safeToRepeat)
    }
    #expect(await session.shutdown() == .killed)
    // The hang this guards against lasts 30 s (the sleep); 10 s leaves room for a loaded machine.
    #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func runsWithArgsAreNeverResent() async throws {
    // Reads two requests, logs them to stderr, answers the first and exits cleanly.
    let script = #"""
        read -r a; echo "$a" >&2
        read -r b; echo "$b" >&2
        id=$(printf '%s' "$a" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id"
        """#
    let session = try TestExtension(script: script).session()
    let first = try await session.submit(
        .number(1), RunParams(command: "go", text: "", revision: 1), retry: .safeToRepeat)
    let action = try await session.submit(
        .number(2), RunParams(command: "go", text: "", revision: 2, args: ["id": .number(7)]), retry: .never)
    #expect(try await first.value.outcome.get() == .close(message: nil))
    await #expect(throws: HostError.notResent) { try await action.value }
    let written = session.stderrTail.split(separator: "\n").filter { $0.contains(#""id":2"#) }
    #expect(written.count == 1)

    // A query in the same position would be resent: oneShotScriptsAreRestartedForEachRequest.
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
}

/// The review's gap: Return on a listed command's row, without args, was classed as a query and
/// resent, so a toggle could run twice. Now only a command that says it is repeatable is resent.
@MainActor
@Test func aListedCommandThatChangesSomethingIsNeverResent() async throws {
    // Reads two requests, logs them to stderr, answers the first and exits cleanly.
    let script = #"""
        read -r a; echo "$a" >&2
        read -r b; echo "$b" >&2
        id=$(printf '%s' "$a" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id"
        """#
    let ext = try TestExtension(
        commands: #"[{"id":"go","title":"Toggle"},{"id":"list","title":"List","repeatable":true}]"#,
        script: script)
    let manifest = try ext.manifest
    let registry = CommandRegistry()
    registry.setExtensionCommands(
        manifest.commands.map { RegisteredCommand(extension: manifest.id, command: $0, icon: nil) })
    let dispatcher = ActionDispatcher(registry: registry, effects: NoEffects())
    func row(_ name: String) throws -> CommandRun {
        let id = CommandID.extension(manifest.id, name)
        let item = try #require(registry.search("").first { $0.id == CommandRegistry.itemID(for: id) })
        guard case .open(let run) = dispatcher.perform(item.actions[0], in: ActionContext()) else {
            throw HostError.unknownCommand
        }
        return run
    }
    let list = try row("list")
    let toggle = try row("go")
    #expect(list.retry == .safeToRepeat)
    #expect(toggle.retry == .never)

    let session = try ext.session()
    func submit(_ id: Int, _ run: CommandRun) async throws -> Task<Reply, any Error> {
        try await session.submit(
            .number(id), RunParams(command: run.invocation.command.name, text: "", revision: id),
            retry: run.retry)
    }
    let first = try await submit(1, list)
    let second = try await submit(2, toggle)
    #expect(try await first.value.outcome.get() == .close(message: nil))
    await #expect(throws: HostError.notResent) { try await second.value }
    let written = session.stderrTail.split(separator: "\n").filter { $0.contains(#""id":2"#) }
    #expect(written.count == 1)
}

@Test func stoppedSessionsRefuseRequests() async throws {
    let session = try TestExtension(script: answering(#"{"close":{}}"#)).session()
    _ = try await session.run("go", text: "", retry: .safeToRepeat)
    await session.stop()
    await #expect(throws: HostError.stopped) { try await session.run("go", text: "", retry: .safeToRepeat) }
    #expect(await session.shutdown() == .notRunning)
}

@MainActor
@Test func shuttingDownStopsEverySessionAndWhatItLeftRunning() async throws {
    // Answers, leaving a child in its own session that holds stdout and ignores stdin closing.
    let script = #"""
        /usr/bin/perl -e '
          use POSIX;
          POSIX::setsid();
          open(my $f, ">", "$ENV{WICKET_DATA_DIR}/pid.new"); print $f "$$"; close $f;
          rename("$ENV{WICKET_DATA_DIR}/pid.new", "$ENV{WICKET_DATA_DIR}/pid");
          sleep 30;
        ' &
        until [ -f "$WICKET_DATA_DIR/pid" ]; do /bin/sleep 0.01; done
        """# + "\n" + answering(#"{"close":{}}"#)
    let ext = try TestExtension(script: script)
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent(), store: testStore()) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    await extensions.load().value
    let command = Invocation(command: try #require(extensions.commands.first).id)
    #expect(try await extensions.result(of: command, retry: .safeToRepeat) == .close(message: nil))
    let child = try #require(pid_t(String(contentsOf: data.appending(path: "pid"), encoding: .utf8)))

    let start = ContinuousClock.now
    await extensions.shutdown()
    #expect(!isRunning(child))
    #expect(ContinuousClock.now - start < .seconds(10))
    // No session starts again.
    await #expect(throws: HostError.stopped) {
        try await extensions.result(of: command, retry: .safeToRepeat)
    }
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
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent(), store: testStore()) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    await extensions.load().value
    let command = Invocation(command: try #require(extensions.commands.first).id)
    #expect(try await extensions.result(of: command, retry: .safeToRepeat) == .close(message: nil))

    try ext.change("main.sh")
    await extensions.load(changed: [ext.folder.appending(path: "main.sh").path]).value
    #expect(try await extensions.result(of: command, retry: .safeToRepeat) == .close(message: nil))
    let log = try String(contentsOf: data.appending(path: "log"), encoding: .utf8)
    #expect(log.split(separator: "\n") == ["start", "end", "start"])

    // A removed extension's commands are unknown, and its session is stopped.
    try FileManager.default.removeItem(at: ext.folder)
    await extensions.load().value
    await #expect(throws: HostError.unknownCommand) {
        try await extensions.result(of: command, retry: .safeToRepeat)
    }
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

@Test func aProcessHasEndedOnlyOnceWhatItLeftRunningHas() async throws {
    // Answers, then exits, leaving a child in its own session that holds stdout, so EOF never comes
    // by itself.
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let script = #"""
        read -r line
        /usr/bin/perl -e '
          use POSIX;
          POSIX::setsid();
          open(my $f, ">", "$ENV{WICKET_DATA_DIR}/pid.new"); print $f "$$"; close $f;
          rename("$ENV{WICKET_DATA_DIR}/pid.new", "$ENV{WICKET_DATA_DIR}/pid");
          sleep 30;
        ' &
        until [ -f "$WICKET_DATA_DIR/pid" ]; do /bin/sleep 0.01; done
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id"
        """#
    let session = try TestExtension(script: script).session { $0.dataDirectory = data }
    let start = ContinuousClock.now
    #expect(try await session.run("go", text: "", retry: .safeToRepeat) == .close(message: nil))
    let child = try #require(
        pid_t(String(contentsOf: data.appending(path: "pid"), encoding: .utf8)))
    #expect(await session.shutdown() == .terminated)
    #expect(!isRunning(child))
    #expect(ContinuousClock.now - start < .seconds(10))
}

@MainActor
@Test func replacementWaitsForWhatTheOldProcessLeftRunning() async throws {
    // Leaves a child in its own session that holds stdout and takes 0.2 s to exit on SIGTERM, logging
    // both; the successor must start after that.
    let script = #"""
        echo start >> "$WICKET_DATA_DIR/log"
        /usr/bin/perl -e '
          use POSIX;
          sub note { open(my $f, ">>", "$ENV{WICKET_DATA_DIR}/$_[0]"); print $f "$_[1]\n"; close $f }
          $SIG{TERM} = sub { note("log", "term"); select(undef, undef, undef, 0.2); note("log", "gone"); exit 0 };
          POSIX::setsid();
          note("ready", "");
          sleep 30;
        ' &
        until [ -f "$WICKET_DATA_DIR/ready" ]; do /bin/sleep 0.01; done
        rm "$WICKET_DATA_DIR/ready"
        \#(answering(#"{"close":{}}"#))
        """#
    let ext = try TestExtension(script: script)
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent(), store: testStore()) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    await extensions.load().value
    let command = Invocation(command: try #require(extensions.commands.first).id)
    #expect(try await extensions.result(of: command, retry: .safeToRepeat) == .close(message: nil))

    try ext.change("main.sh")
    await extensions.load(changed: [ext.folder.appending(path: "main.sh").path]).value
    #expect(try await extensions.result(of: command, retry: .safeToRepeat) == .close(message: nil))
    let log = try String(contentsOf: data.appending(path: "log"), encoding: .utf8)
    #expect(log.split(separator: "\n") == ["start", "term", "gone", "start"])

    try FileManager.default.removeItem(at: ext.folder)
    await extensions.load().value
    await #expect(throws: HostError.unknownCommand) {
        try await extensions.result(of: command, retry: .safeToRepeat)
    }
}
