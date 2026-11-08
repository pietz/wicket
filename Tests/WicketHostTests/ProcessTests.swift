import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// One run of an extension's program: the request on stdin, one response on stdout, and every way
// of giving up on it ends with the process and everything it started gone.

@Test func eachRunIsAFreshProcessGivenTheRequestOnStdin() async throws {
    let script = #"""
        request=$(cat)
        jq -nc --arg r "$request" --arg pid "$$" '{answer: {title: $pid, subtitle: $r}}'
        """#
    let ext = try TestExtension(script: script)
    var pids: Set<String> = []
    for _ in 0..<2 {
        let run = try await ext.run(text: "a/b", args: ["n": .integer(1)])
        guard case .show(.answer(let item), _) = try run.result.get() else {
            Issue.record("not an answer")
            return
        }
        #expect(item.subtitle == #"{"args":{"n":1},"command":"go","text":"a/b"}"#)
        pids.insert(item.title)
    }
    #expect(pids.count == 2)
}

@Test func environmentAndSecrets() async throws {
    let script = answering(#"{"answer":{"title":"'"$WICKET_PROTOCOL $WICKET_EXTENSION_ID $TOKEN $LANG"'"}}"#)
    let ext = try TestExtension(
        id: "env", secrets: #"[{"name":"TOKEN","title":"API token"}]"#, script: script)
    let run = await ExtensionProcess.run(
        Request(command: "go", text: ""), manifest: try ext.manifest, folder: ext.folder,
        configuration: testConfiguration(secrets: ["TOKEN": "s3cret"]))
    guard case .show(.answer(let item), _) = try run.result.get() else {
        Issue.record("not an answer")
        return
    }
    #expect(item.title.hasPrefix("2 env s3cret "))
    #expect(item.title.hasSuffix(".UTF-8"))
    #expect(run.secrets == ["s3cret"])

    let missing = try await ext.run()
    #expect(throws: HostError.missingSecret(extensionID: "env", name: "TOKEN", title: "API token")) {
        try missing.result.get()
    }
}

@Test func anErrorResponseIsTheExtensionsOwnWithItsStderr() async throws {
    let script =
        #"cat >/dev/null; echo 'token rejected' >&2; echo '{"error":{"message":"GitHub token expired"}}'"#
    let run = try await TestExtension(script: script).run()
    #expect(throws: ExtensionError.self) { try run.result.get() }
    if case .failure(let error as ExtensionError) = run.result {
        #expect(error.message == "GitHub token expired")
    }
    #expect(run.stderr == "token rejected\n")
}

@Test func whatIsntAResponseIsNamed() async throws {
    let silent = try await TestExtension(script: "cat >/dev/null; echo crashed >&2; exit 3").run()
    #expect(throws: HostError.exited(.status(3))) { try silent.result.get() }
    #expect(silent.stderr == "crashed\n")

    let chatty = try await TestExtension(script: "cat >/dev/null; echo starting; echo '{}'").run()
    #expect {
        try chatty.result.get()
    } throws: {
        "\($0)".contains("write logs to stderr")
    }
}

/// A response counts only when the program exits cleanly: JSON followed by an error status or a
/// kill is a failure, recorded as a crash with its stderr.
@Test func aResponseCountsOnlyAfterACleanExit() async throws {
    let failing = try await TestExtension(
        script: #"cat >/dev/null; echo '{"close":{}}'; echo 'disk full' >&2; exit 7"#
    ).run()
    #expect(throws: HostError.exitedAfterAnswering(.status(7))) { try failing.result.get() }
    #expect(failing.stderr == "disk full\n")
    if case .failure(let error) = failing.result { #expect(ExtensionHistory.Outcome(error) == .crashed) }

    let killed = try await TestExtension(script: #"cat >/dev/null; echo '{"close":{}}'; kill -KILL $$"#).run()
    #expect(throws: HostError.exitedAfterAnswering(.signal(SIGKILL))) { try killed.result.get() }
}

@Test func slowRunsTimeOut() async throws {
    let start = ContinuousClock.now
    let run = try await TestExtension(script: "exec /bin/sleep 30").run { $0.timeout = .milliseconds(300) }
    #expect(throws: HostError.timeout(.milliseconds(300))) { try run.result.get() }
    #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func overlongOutputEscalatesToSIGKILL() async throws {
    // Ignores SIGTERM (the disposition survives exec).
    let script = #"trap '' TERM; cat >/dev/null; head -c 1100000 /dev/zero | tr '\0' 'a'; exec /bin/sleep 30"#
    let start = ContinuousClock.now
    let run = try await TestExtension(script: script).run()
    #expect(throws: HostError.outputTooLong) { try run.result.get() }
    // The hang this guards against lasts 30 s (the sleep); 10 s leaves room for a loaded machine.
    #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func missingProgramsAreNamed() async throws {
    let ext = try TestExtension(script: "")
    var manifest = try ext.manifest
    manifest.run = ["no-such-interpreter-wicket", "main.sh"]
    let run = await ExtensionProcess.run(
        Request(command: "go", text: ""), manifest: manifest, folder: ext.folder,
        configuration: testConfiguration())
    #expect {
        try run.result.get()
    } throws: {
        "\($0)".contains("no-such-interpreter-wicket in run was not found on the login shell PATH")
    }
}

/// A script that starts a child in its own session (so a process-group kill misses it), which writes
/// its pid to `$WICKET_DATA_DIR/pid` and sleeps; the script waits for the file, then runs `then`.
private func leavingAChild(then: String) -> String {
    #"""
    cat >/dev/null
    /usr/bin/perl -e '
      use POSIX;
      POSIX::setsid();
      open(my $f, ">", "$ENV{WICKET_DATA_DIR}/pid.new"); print $f "$$"; close $f;
      rename("$ENV{WICKET_DATA_DIR}/pid.new", "$ENV{WICKET_DATA_DIR}/pid");
      sleep 30;
    ' &
    until [ -f "$WICKET_DATA_DIR/pid" ]; do /bin/sleep 0.01; done
    """# + "\n" + then
}

private func child(in data: URL) throws -> pid_t {
    try #require(pid_t(String(contentsOf: data.appending(path: "pid"), encoding: .utf8)))
}

@Test func aRunEndsOnlyOnceWhatItLeftRunningHas() async throws {
    // The child holds stdout, so end of file never comes by itself.
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let ext = try TestExtension(script: leavingAChild(then: #"echo '{"close":{}}'"#))
    let start = ContinuousClock.now
    let run = try await ext.run { $0.dataDirectory = data }
    #expect(try run.result.get() == .close(message: nil))
    #expect(!isRunning(try child(in: data)))
    #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func cancellingStopsTheTreeAndReturnsOnceItIsGone() async throws {
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let ext = try TestExtension(script: leavingAChild(then: "exec /bin/sleep 30"))
    let start = ContinuousClock.now
    let task = Task { try await ext.run { $0.dataDirectory = data } }
    while !FileManager.default.fileExists(atPath: data.appending(path: "pid").path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    let run = try await task.value
    #expect(throws: CancellationError.self) { try run.result.get() }
    #expect(!isRunning(try child(in: data)))
    #expect(ContinuousClock.now - start < .seconds(10))
}
