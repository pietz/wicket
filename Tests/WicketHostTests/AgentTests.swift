import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The agents here are shell scripts standing in for `codex` and `claude`. Most replay streams recorded
// from the real CLIs (Fixtures/, scrubbed of personal paths and account details; the Codex recordings
// were made before the adapter read the config, so their config/read reply is trimmed by hand).

/// A fake agent executable named like the real one, running `script` with /bin/sh.
func fakeAgent(_ provider: AgentProvider, _ script: String) throws -> Agent {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: provider.command)
    try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return Agent(provider: provider, executable: url)
}

/// A fake agent that prints a recorded stream and exits, ignoring what it is sent.
func replaying(_ provider: AgentProvider, _ fixture: String) throws -> Agent {
    let url = try #require(
        Bundle.module.url(forResource: fixture, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try fakeAgent(provider, "exec /bin/cat '\(url.path)'")
}

func events(_ agent: Agent, _ mode: AgentMode = .answer) async -> [AgentEvent] {
    let request = AgentRequest(
        prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: mode)
    var events: [AgentEvent] = []
    for await event in agent.run(request) { events.append(event) }
    return events
}

func text(_ events: [AgentEvent]) -> String {
    events.map { if case .text(let text) = $0 { text } else { "" } }.joined()
}

func activities(_ events: [AgentEvent]) -> [String] {
    events.compactMap { if case .activity(let activity) = $0 { activity } else { nil } }
}

@Suite struct CodexTests {
    @Test func streamsAnAnswer() async throws {
        let events = await events(try replaying(.codex, "codex-answer"))
        #expect(
            events == [
                .text("Paris"),
                .answer(
                    "Paris", usage: AgentUsage(inputTokens: 4347, cachedInputTokens: 2432, outputTokens: 5)),
            ])
    }

    @Test func toolRunReportsActivityAndTheFinalMessage() async throws {
        let events = await events(try replaying(.codex, "codex-build"))
        #expect(activities(events) == ["Ran printf hi > hello.txt"])
        // Commentary streams too, set apart from the answer by a blank line.
        #expect(
            text(events).hasPrefix(
                "I’ll create `hello.txt`, run the exact shell command once, and report the results.\n\n- Created"
            ))
        guard case .answer(let answer, let usage)? = events.last else {
            Issue.record("no answer: \(events)")
            return
        }
        #expect(answer.hasPrefix("- Created `hello.txt` containing `hi`."))
        #expect(answer.contains("Operation not permitted"))
        #expect(usage == AgentUsage(inputTokens: 20360, cachedInputTokens: 17408, outputTokens: 132))
    }

    @Test func loggedOutRunShowsRetriesThenFails() async throws {
        let events = await events(try replaying(.codex, "codex-loggedout"))
        #expect(activities(events).first == "Reconnecting... 2/5")
        guard case .error(let message)? = events.last else {
            Issue.record("no error: \(events)")
            return
        }
        #expect(message.hasPrefix("unexpected status 401 Unauthorized"))
    }

    @Test func requestsFollowTheProtocol() throws {
        let folder = URL(filePath: "/tmp/stage")
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hello", workingDirectory: folder, mode: .answer))
        #expect(try methods(transcript.start()) == ["initialize", "initialized", "config/read"])

        let thread = try sent(
            transcript.receive(line(#"{"id":2,"result":{"config":{"mcp_servers":{"docs":{"url":"x"}}}}}"#)))
        #expect(thread["method"] == .string("thread/start"))
        #expect(thread["params"]?["cwd"] == .string("/tmp/stage"))
        #expect(thread["params"]?["sandbox"] == .string("read-only"))
        #expect(thread["params"]?["approvalPolicy"] == .string("never"))
        #expect(thread["params"]?["config"]?["mcp_servers"]?["docs"]?["enabled"] == .bool(false))

        let turn = try sent(transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#)))
        #expect(turn["method"] == .string("turn/start"))
        #expect(turn["params"]?["threadId"] == .string("t1"))
        #expect(turn["params"]?["input"]?.array?.first?["text"] == .string("Hello"))
        #expect(turn["params"]?["effort"] == .string("low"))
    }

    @Test func answerRunsAreReadOnlyWithoutTools() throws {
        let arguments = CodexTranscript.arguments(for: .answer)
        #expect(arguments.first == "app-server")
        for feature in ["shell_tool", "unified_exec", "code_mode_host", "hooks", "plugins", "apps"] {
            #expect(arguments.contains("features.\(feature)=false"))
        }

        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .answer))
        _ = transcript.start()
        let thread = try sent(transcript.receive(line(#"{"id":2,"result":{"config":{}}}"#)))
        #expect(thread["params"]?["sandbox"] == .string("read-only"))
        #expect(thread["params"]?["baseInstructions"] == .string(Agent.answerInstructions))
    }

    @Test func lockedDownRunsRefuseServerRequests() throws {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .answer))
        let step = transcript.receive(
            line(
                #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"command":"rm -rf /"}}"#)
        )
        #expect(step.events == [.activity("Declined item/commandExecution/requestApproval")])
        let reply = try sent(step)
        #expect(reply["id"] == .integer(7))
        #expect(reply["error"]?["code"] == .integer(-32601))
    }

    @Test func actingRunsLeaveApprovalsSandboxAndServersToTheUsersConfig() throws {
        #expect(CodexTranscript.arguments(for: .act) == ["app-server"])
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Tidy up", workingDirectory: URL(filePath: "/tmp/work"), mode: .act)
        )
        let start = transcript.start()
        #expect(try methods(start) == ["initialize", "initialized", "thread/start"])
        let thread = try decoded(start.send[2])["params"]
        #expect(thread?["cwd"] == .string("/tmp/work"))
        #expect(thread?["ephemeral"] == .bool(true))
        #expect(thread?["developerInstructions"] == .string(Agent.actInstructions))
        for omitted in ["approvalPolicy", "sandbox", "config", "baseInstructions"] {
            #expect(thread?[omitted] == nil)
        }
        let turn = try sent(transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#)))
        #expect(turn["method"] == .string("turn/start"))
        #expect(turn["params"]?["effort"] == nil)
        #expect(turn["params"]?["sandboxPolicy"] == nil)
    }

    @Test func approvalsWaitForTheUserUntilResolved() throws {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/work"), mode: .act))
        _ = transcript.start()
        let command = AgentApproval(
            id: .integer(0), kind: .command, subject: "echo hi > hello.txt", reason: "Create hello.txt?")
        let first = transcript.receive(
            line(
                #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"itemId":"c1","reason":"Create hello.txt?","command":"/bin/zsh -lc 'echo hi > hello.txt'","commandActions":[{"type":"unknown","command":"echo hi"}]}}"#
            ))
        #expect(first.events == [.approvals([command])])
        #expect(first.send.isEmpty)

        // A file-change approval names its item; the item said what changes.
        _ = transcript.receive(
            line(
                #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"/tmp/work/notes.md","kind":{"type":"add"},"diff":"hi"},{"path":"/tmp/work/a.swift","kind":{"type":"update","move_path":null},"diff":""}]}}}"#
            ))
        let files = AgentApproval(
            id: .string("r2"), kind: .fileChange, subject: "add notes.md, update a.swift")
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/fileChange/requestApproval","id":"r2","params":{"itemId":"f1","reason":null}}"#
                )
            ).events == [.approvals([command, files])])

        // Replies keep the request id's type.
        let accepted = try decoded(
            try #require(CodexTranscript.reply(AgentReply(approval: command, decision: .acceptForSession))))
        #expect(
            accepted
                == .object(["id": .integer(0), "result": .object(["decision": .string("acceptForSession")])]))
        let declined = try decoded(
            try #require(CodexTranscript.reply(AgentReply(approval: files, decision: .decline))))
        #expect(declined["id"] == .string("r2"))

        #expect(
            transcript.receive(
                line(#"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":0}}"#)
            )
            .events == [.approvals([files])])
        #expect(
            transcript.receive(
                line(#"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":"r2"}}"#)
            ).events == [.approvals([])])
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/completed","params":{"item":{"type":"fileChange","id":"f1","status":"declined","changes":[{"path":"/tmp/work/notes.md","kind":{"type":"add"},"diff":"hi"}]}}}"#
                )
            ).events == [.activity("Declined changes to notes.md")])
    }

    @Test func approvalsSayWhereAndWhatUnambiguously() throws {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/work"), mode: .act))
        _ = transcript.start()
        // A managed-network prompt names its host and protocol, not the command behind it.
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/commandExecution/requestApproval","id":1,"params":{"itemId":"c1","command":"curl https://api.github.com","cwd":"/tmp/work","networkApprovalContext":{"host":"api.github.com","protocol":"https"}}}"#
                )
            ).events == [
                .approvals([AgentApproval(id: .integer(1), kind: .network, subject: "api.github.com (https)")]
                )
            ])
        _ = transcript.receive(
            line(#"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":1}}"#))
        // Paths inside the run's folder are relative to it, others absolute; the root it asks for stays.
        _ = transcript.receive(
            line(
                #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"/tmp/work/Sources/a.swift","kind":{"type":"update"}},{"path":"/tmp/workshop/notes.md","kind":{"type":"add"}},{"path":"b.txt","kind":{"type":"delete"}}]}}}"#
            ))
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/fileChange/requestApproval","id":2,"params":{"itemId":"f1","grantRoot":"/tmp/workshop"}}"#
                )
            ).events == [
                .approvals([
                    AgentApproval(
                        id: .integer(2), kind: .fileChange,
                        subject: "update Sources/a.swift, add /tmp/workshop/notes.md, delete b.txt",
                        grantRoot: "/tmp/workshop")
                ])
            ])
    }

    @Test func actingRunsStillRefuseOtherRequests() throws {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .act))
        let step = transcript.receive(
            line(#"{"id":5,"method":"item/tool/requestUserInput","params":{"questions":[]}}"#))
        #expect(step.events == [.activity("Declined item/tool/requestUserInput")])
        #expect(try sent(step)["error"]?["code"] == .integer(-32601))
    }

    @Test func aRecordedApprovalRoundTrip() async throws {
        // Recorded from Codex 0.167 with a temporary config (on-request, read-only), the command
        // accepted; the replay ignores what it is sent.
        let events = await events(try replaying(.codex, "codex-act-approval"), .act)
        let approval = AgentApproval(
            id: .integer(0), kind: .command, subject: "echo hi > hello.txt",
            reason: "Allow creating hello.txt with the requested content?", workingDirectory: "/tmp/work")
        #expect(
            events.filter { if case .approvals = $0 { true } else { false } } == [
                .approvals([approval]), .approvals([]),
            ])
        #expect(activities(events) == ["Ran echo hi > hello.txt"])
        guard case .answer(let answer, _)? = events.last else {
            Issue.record("no answer: \(events)")
            return
        }
        #expect(answer == "done")
    }

    @Test func aRequestErrorEndsTheRun() {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .answer))
        let step = transcript.receive(line(#"{"id":3,"error":{"code":-32600,"message":"bad cwd"}}"#))
        #expect(step.events == [.error("bad cwd")])
    }

    @Test func aReplyReachesTheAgentWhileItWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let replyFile = folder.appending(path: "reply")
        let agent = try fakeAgent(
            .codex,
            """
            echo '{"method":"item/commandExecution/requestApproval","id":"a","params":{"command":"ls"}}'
            while read -r line; do case "$line" in *decision*) printf '%s' "$line" > '\(replyFile.path)'; break;; esac; done
            echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"ok"}}}'
            echo '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            """)
        let run = agent.run(AgentRequest(prompt: "test", workingDirectory: folder, mode: .act))
        var last: AgentEvent?
        for await event in run {
            if case .approvals(let approvals) = event, let first = approvals.first {
                run.reply(to: first, .accept)
            }
            last = event
        }
        #expect(last == .answer("ok", usage: nil))
        let reply = try decoded(try Data(contentsOf: replyFile))
        #expect(reply == .object(["id": .string("a"), "result": .object(["decision": .string("accept")])]))
    }

    private func line(_ text: String) -> Data { Data(text.utf8) }

    private func decoded(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func methods(_ step: AgentStep) throws -> [String] {
        try step.send.map { try decoded($0)["method"]?.string ?? "" }
    }

    /// The one message a step sends.
    private func sent(_ step: AgentStep) throws -> JSONValue {
        try #require(step.send.count == 1)
        return try decoded(step.send[0])
    }
}

@Suite struct ClaudeTests {
    @Test func streamsAnAnswer() async throws {
        let events = await events(try replaying(.claude, "claude-answer"))
        #expect(
            events == [
                .text("Paris"),
                .answer("Paris", usage: AgentUsage(inputTokens: 985, cachedInputTokens: 0, outputTokens: 5)),
            ])
    }

    @Test func toolRunReportsActivity() async throws {
        let events = await events(try replaying(.claude, "claude-build"))
        #expect(activities(events) == ["Edited hello.txt", "Ran cat hello.txt && touch ../escape-bash.txt"])
        guard case .answer(let answer, let usage)? = events.last else {
            Issue.record("no answer: \(events)")
            return
        }
        #expect(text(events) == answer)
        #expect(answer.hasPrefix("Step 1 worked."))
        #expect(usage == AgentUsage(inputTokens: 20723, cachedInputTokens: 16278, outputTokens: 370))
    }

    @Test func loggedOutRunFails() async throws {
        let events = await events(try replaying(.claude, "claude-loggedout"))
        #expect(events == [.error("Not logged in · Please run /login")])
    }

    @Test func promptGoesToStdinAndModesSetTheTools() async throws {
        // Echoes its stdin back as a text delta, then succeeds.
        let agent = try fakeAgent(
            .claude,
            #"""
            prompt=$(cat)
            printf '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$prompt"
            echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
            """#)
        #expect(await events(agent).first == .text("test"))

        let answer = ClaudeTranscript.arguments(for: .answer)
        #expect(answer.firstIndex(of: "--tools").map { answer[$0 + 1] } == "")
        #expect(answer.contains("--safe-mode") && answer.contains("--strict-mcp-config"))
        #expect(ClaudeTranscript.arguments(for: .act) == answer)
    }
}

@Suite struct AgentProcessTests {
    @Test func reportsAnExitWithoutResult() async throws {
        let agent = try fakeAgent(.claude, "echo 'something went wrong' >&2\nexit 3")
        #expect(
            await events(agent) == [
                .error("claude exited with status 3 before finishing: something went wrong")
            ])
    }

    @Test func missingExecutableIsAnError() async {
        let agent = Agent(provider: .codex, executable: URL(filePath: "/nonexistent/codex"))
        guard case .error(let message)? = await events(agent).last else {
            Issue.record("no error")
            return
        }
        #expect(message.hasPrefix("could not start /nonexistent/codex"))
    }

    @Test func cancellingKillsTheProcessTree() async throws {
        let pids = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/pids-\(UUID().uuidString)")
        // A child in its own session, as Codex runs commands, so a process group kill would miss it.
        let agent = try fakeAgent(
            .claude,
            """
            /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 60' &
            echo "$$ $!" > '\(pids.path)'
            echo '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"working"}}}'
            sleep 60
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
        let consumer = Task {
            for await event in agent.run(request) {
                if case .text = event { return true }
            }
            return false
        }
        #expect(await consumer.value)
        // Returning from the loop ended the stream, which cancels the run.
        let started = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(started.count == 2)
        var alive = started
        for _ in 0..<50 where !alive.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            alive = alive.filter { kill($0, 0) == 0 }
        }
        #expect(alive.isEmpty)
    }

    @Test func cancellingAfterTheAgentExitedStopsWhatItLeft() async throws {
        let pids = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/pids-\(UUID().uuidString)")
        // Exits mid-run, leaving a child in its own session that holds stdout: with the parent gone,
        // only the pipe links them.
        let agent = try fakeAgent(
            .claude,
            """
            echo $$ > '\(pids.path)'
            /usr/bin/perl -e '
              use POSIX;
              POSIX::setsid();
              open(my $f, ">>", $ARGV[0]); print $f "$$\\n"; close $f;
              $| = 1;
              print qq({"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"working"}}}\\n);
              sleep 60;
            ' '\(pids.path)' &
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
        let consumer = Task {
            for await event in agent.run(request) {
                guard case .text = event else { continue }
                // End the run once the agent itself has exited.
                let parent = try #require(
                    String(contentsOf: pids, encoding: .utf8).split(separator: "\n").first.flatMap {
                        pid_t($0)
                    })
                return await within10s { !isRunning(parent) }
            }
            return false
        }
        #expect(try await consumer.value)
        let started = try String(contentsOf: pids, encoding: .utf8).split(separator: "\n").compactMap {
            pid_t($0)
        }
        #expect(started.count == 2)
        #expect(await within10s { !started.contains(where: isRunning) })
    }

    /// What a build would seal: the answer comes after the agent's child finished writing.
    @Test func theAnswerComesAfterWhatTheAgentLeftRunningHasExited() async throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/written-\(UUID().uuidString)")
        // Answers and exits while a background job (its process group, stdout closed) still writes.
        let agent = try fakeAgent(
            .claude,
            """
            ( /bin/sleep 0.3; echo written > '\(file.path)' ) >/dev/null 2>&1 &
            echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
        let run = AgentProcess.run(
            agent.executable, arguments: [], request: request, transcript: ClaudeTranscript(request: request))
        var answered = false
        for await event in run {
            guard case .answer = event else { continue }
            answered = true
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(answered)
        #expect(await run.ended == .exited(.status(0)))
    }

    /// A child still running a grace after the answer is terminated before the answer comes.
    @Test func aChildOutlivingTheGraceIsStoppedBeforeTheAnswer() async throws {
        let pid = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/pid-\(UUID().uuidString)")
        let agent = try fakeAgent(
            .claude,
            """
            /bin/sleep 30 >/dev/null 2>&1 &
            echo $! > '\(pid.path)'
            echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
        let start = ContinuousClock.now
        let run = AgentProcess.run(
            agent.executable, arguments: [], request: request, transcript: ClaudeTranscript(request: request),
            exitGrace: .milliseconds(300))
        var answered = false
        for await event in run {
            guard case .answer = event else { continue }
            answered = true
            let child = try #require(
                pid_t(
                    String(contentsOf: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(!isRunning(child))
        }
        #expect(answered)
        #expect(await run.ended == .terminated)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func cancelAndWaitReturnsOnceTheTreeIsGone() async throws {
        let pids = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/pids-\(UUID().uuidString)")
        // A child in its own session, as Codex runs commands.
        let agent = try fakeAgent(
            .claude,
            """
            /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 60' &
            echo "$$ $!" > '\(pids.path)'
            echo '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"working"}}}'
            sleep 60
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, mode: .answer)
        let run = agent.run(request)
        var events: [AgentEvent] = []
        for await event in run {
            events.append(event)
            if case .text = event { #expect(await run.cancelAndWait() == .terminated) }
        }
        // No final event after a cancel, and nothing left running the moment it returned.
        #expect(events == [.text("working")])
        let started = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(started.count == 2)
        #expect(!started.contains(where: isRunning))
    }

    @Test func splitsLinesAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.split(Data("a\nb".utf8)) == [Data("a".utf8)])
        #expect(splitter.split(Data("c\n\nd\n".utf8)) == [Data("bc".utf8), Data("d".utf8)])
    }
}

@Suite struct AgentStatusTests {
    private let script = """
        case "$1" in
          --version) echo 'codex-cli 0.167.2' ;;
          login) [ -f "$(dirname "$0")/logged-in" ] ;;
        esac
        """

    @Test func readyWhenLoggedIn() async throws {
        let agent = try fakeAgent(.codex, script)
        FileManager.default.createFile(
            atPath: agent.executable.deletingLastPathComponent().appending(path: "logged-in").path,
            contents: nil)
        let status = await agent.status()
        #expect(status == AgentStatus(provider: .codex, state: .ready, version: "0.167.2"))
        #expect(status.warning == nil)
        #expect(status.description == "Codex 0.167.2 is ready")
    }

    @Test func loggedOut() async throws {
        let status = try await fakeAgent(.codex, script).status()
        #expect(status.state == .loggedOut)
        #expect(status.description == "Codex 0.167.2 is not logged in; run `codex login` in Terminal")
    }

    @Test func untestedVersionWarns() {
        let status = AgentStatus(provider: .claude, state: .ready, version: "2.2.0")
        #expect(status.warning == "untested version 2.2.0 (Wicket was tested with 2.1.x)")
        #expect(AgentStatus(provider: .claude, state: .ready, version: "2.1.400").warning == nil)
    }

    @Test func parsesVersions() {
        #expect(Agent.version(in: "codex-cli 0.167.0\n") == "0.167.0")
        #expect(Agent.version(in: "2.1.318 (Claude Code)") == "2.1.318")
        #expect(Agent.version(in: "unknown") == nil)
    }
}
