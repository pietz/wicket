import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// Each adapter replays streams recorded from the real CLIs (Fixtures/, scrubbed of personal details)
// line by line, and answers hand-written lines for what the recordings don't cover. Real processes
// (shell scripts standing in for `codex` and `claude`) test what only a process can show: replies
// reaching a waiting agent, completion ordering, cancellation and cleanup.

/// Claude's defaults, for tests where the choices don't matter.
let defaults = AgentProvider.claude.defaultOptions

private let work = URL(filePath: "/tmp/work")

private func request(instructions: String? = nil, resume: String? = nil) -> AgentRequest {
    AgentRequest(
        prompt: "Hi", workingDirectory: work, options: defaults, instructions: instructions, resume: resume)
}

private func line(_ text: String) -> Data { Data(text.utf8) }

private func decoded(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

private func sent(_ step: AgentStep, _ index: Int = 0) throws -> JSONValue {
    try decoded(try #require(step.send.dropFirst(index).first))
}

/// The events a transcript makes of a recorded stream, fed line by line after its start.
private func replay(_ transcript: some AgentTranscript, _ fixture: String) throws -> [AgentEvent] {
    var transcript = transcript
    let url = try #require(
        Bundle.module.url(forResource: fixture, withExtension: "jsonl", subdirectory: "Fixtures"))
    _ = transcript.start()
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").flatMap {
        transcript.receive(line(String($0))).events
    }
}

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

func events(_ agent: Agent) async -> [AgentEvent] {
    let request = AgentRequest(
        prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, options: defaults)
    var events: [AgentEvent] = []
    for await event in agent.run(request) { events.append(event) }
    return events
}

/// A line that makes the Claude transcript yield a message.
private let claudeMessage =
    #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"working"}]}}"#

@Suite struct CodexTests {
    @Test func aRecordedRunShowsEachWholeMessageThenTheAnswer() throws {
        let events = try replay(CodexTranscript(request: request()), "codex-build")
        let intro = "I’ll create `hello.txt`, run the exact shell command once, and report the results."
        guard case .answer(let answer)? = events.last else {
            Issue.record("no answer: \(events)")
            return
        }
        #expect(answer.hasPrefix("- Created `hello.txt` containing `hi`."))
        #expect(
            events == [
                .session("01a1b1f7-16fa-7393-b7b7-43f2509a1060"), .message(intro), .message(answer),
                .answer(answer),
            ])
    }

    /// Recorded from Codex 0.167 with a temporary config (on-request, read-only), the command accepted.
    @Test func aRecordedApprovalRoundTrip() throws {
        let events = try replay(CodexTranscript(request: request()), "codex-act-approval")
        let approval = AgentApproval(
            id: .integer(0), kind: .command, subject: "echo hi > hello.txt",
            reason: "Allow creating hello.txt with the requested content?", workingDirectory: "/tmp/work")
        #expect(
            events.filter { if case .approvals = $0 { true } else { false } } == [
                .approvals([approval]), .approvals([]),
            ])
        #expect(events.last == .answer("done"))
        let reply = try decoded(
            try #require(CodexTranscript.reply(AgentReply(approval: approval, decision: .accept))))
        #expect(reply == .object(["id": .integer(0), "result": .object(["decision": .string("accept")])]))
    }

    @Test func aRecordedLoggedOutRunFailsAfterItsRetries() throws {
        let events = try replay(CodexTranscript(request: request()), "codex-loggedout")
        guard case .error(let message)? = events.last else {
            Issue.record("no error: \(events)")
            return
        }
        #expect(message.hasPrefix("unexpected status 401 Unauthorized"))
        #expect(events.count == 2)  // The session, then the failure: retries show nothing.
    }

    @Test func aNewThreadKeepsTheUsersSetupAndGetsTheInstructions() throws {
        var transcript = CodexTranscript(request: request(instructions: "Be brief."))
        let start = transcript.start()
        #expect(
            try start.send.map { try decoded($0)["method"] } == [
                .string("initialize"), .string("initialized"), .string("thread/start"),
            ])
        let thread = try sent(start, 2)["params"]
        #expect(
            thread == .object(["cwd": .string("/tmp/work"), "developerInstructions": .string("Be brief.")]))
        let started = transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#))
        #expect(started.events == [.session("t1")])
        let turn = try sent(started)
        #expect(turn["method"] == .string("turn/start"))
        #expect(turn["params"]?["threadId"] == .string("t1"))
        #expect(turn["params"]?["input"]?.array?.first?["text"] == .string("Hi"))
    }

    @Test func aFollowUpResumesItsThreadWithThePolicyConfiguredNow() throws {
        var transcript = CodexTranscript(request: request(instructions: "Be brief.", resume: "t1"))
        #expect(try sent(transcript.start(), 2)["method"] == .string("config/read"))
        let read = transcript.receive(
            line(#"{"id":2,"result":{"config":{"approval_policy":"never","sandbox_mode":"read-only"}}}"#))
        let resume = try sent(read)
        #expect(resume["method"] == .string("thread/resume"))
        #expect(
            resume["params"]
                == .object([
                    "threadId": .string("t1"), "cwd": .string("/tmp/work"), "excludeTurns": .bool(true),
                    "developerInstructions": .string("Be brief."), "approvalPolicy": .string("never"),
                    "sandbox": .string("read-only"),
                ]))
        let resumed = transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#))
        #expect(resumed.events == [.session("t1")])
    }

    @Test func approvalsSayWhereAndWhatUntilResolved() throws {
        var transcript = CodexTranscript(request: request())
        _ = transcript.start()
        // The whole command, unwrapped from the login shell; its folder as given.
        let command = AgentApproval(
            id: .integer(0), kind: .command, subject: "echo hi > a.txt", reason: "Create it?",
            workingDirectory: "/tmp/work")
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"itemId":"c1","command":"/bin/zsh -lc 'echo hi > a.txt'","cwd":"/tmp/work","reason":"Create it?"}}"#
                )
            ).events == [.approvals([command])])
        // A managed-network prompt names its host and protocol, not the command behind it.
        let network = AgentApproval(id: .integer(1), kind: .network, subject: "api.github.com (https)")
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/commandExecution/requestApproval","id":1,"params":{"command":"curl https://api.github.com","networkApprovalContext":{"host":"api.github.com","protocol":"https"}}}"#
                )
            ).events == [.approvals([command, network])])
        // Paths inside the run's folder are relative to it, others absolute; the root it asks for stays.
        _ = transcript.receive(
            line(
                #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"f1","changes":[{"path":"/tmp/work/Sources/a.swift","kind":{"type":"update"}},{"path":"/tmp/workshop/notes.md","kind":{"type":"add"}},{"path":"b.txt","kind":{"type":"delete"}}]}}}"#
            ))
        let files = AgentApproval(
            id: .string("r2"), kind: .fileChange,
            subject: "update Sources/a.swift, add /tmp/workshop/notes.md, delete b.txt",
            grantRoot: "/tmp/workshop")
        #expect(
            transcript.receive(
                line(
                    #"{"method":"item/fileChange/requestApproval","id":"r2","params":{"itemId":"f1","grantRoot":"/tmp/workshop"}}"#
                )
            ).events == [.approvals([command, network, files])])
        // Replies keep the request id's type.
        let declined = try decoded(
            try #require(CodexTranscript.reply(AgentReply(approval: files, decision: .decline))))
        #expect(
            declined == .object(["id": .string("r2"), "result": .object(["decision": .string("decline")])]))
        #expect(
            transcript.receive(line(#"{"method":"serverRequest/resolved","params":{"requestId":"r2"}}"#))
                .events == [
                    .approvals([command, network])
                ])
    }

    @Test func otherRequestsAreRefusedAndARequestErrorEndsTheRun() throws {
        var transcript = CodexTranscript(request: request())
        let step = transcript.receive(
            line(#"{"id":5,"method":"item/tool/requestUserInput","params":{"questions":[]}}"#))
        #expect(step.events.isEmpty)
        #expect(try sent(step)["id"] == .integer(5))
        #expect(try sent(step)["error"]?["code"] == .integer(-32601))
        #expect(
            transcript.receive(line(#"{"id":3,"error":{"message":"bad cwd"}}"#)).events == [.error("bad cwd")]
        )
    }
}

@Suite struct ClaudeTests {
    /// Recorded from Claude Code 2.1.319 with Wicket's flags in a folder whose settings ask before
    /// commands, the command allowed.
    @Test func aRecordedApprovalRoundTrip() throws {
        let events = try replay(ClaudeTranscript(request: request()), "claude-act")
        let approval = try #require(
            events.compactMap { if case .approvals(let a) = $0 { a.first } else { nil } }.first)
        #expect(
            events == [
                .message("I'll write \"hi\" into hello.txt by running the echo command you specified."),
                .approvals([approval]), .approvals([]), .message("Done, hello.txt says hi."),
                .session("dcf4941e-14f7-44bf-ba8e-0a4142f489b1"), .answer("Done, hello.txt says hi."),
            ])
        // No folder: Claude Code's shell keeps its `cd`s and the prompt doesn't say where it is.
        #expect(approval.kind == .command && approval.subject == "echo hi > hello.txt")
        #expect(approval.reason == "Write hi into hello.txt" && approval.workingDirectory == nil)
        // Allow echoes the input and grants nothing more: Claude's suggestions go unused.
        let allowed = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: approval, decision: .accept))))
        #expect(allowed["type"] == .string("control_response"))
        #expect(allowed["response"]?["request_id"] == .string("5f468d3c-8c72-4414-9ad3-eee296d6b85f"))
        #expect(
            allowed["response"]?["response"]
                == .object([
                    "behavior": .string("allow"),
                    "updatedInput": .object([
                        "command": .string("echo hi > hello.txt"),
                        "description": .string("Write hi into hello.txt"),
                    ]),
                ]))
        let denied = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: approval, decision: .decline))))
        #expect(denied["response"]?["response"]?["behavior"] == .string("deny"))
    }

    @Test func aRecordedLoggedOutRunFails() throws {
        let events = try replay(ClaudeTranscript(request: request()), "claude-loggedout")
        #expect(events.last == .error("Not logged in · Please run /login"))
    }

    @Test func runsKeepTheUsersSetupAndAFollowUpResumesTheSession() throws {
        let arguments = ClaudeTranscript.arguments(for: request(instructions: "About Wicket."))
        #expect(
            arguments.firstIndex(of: "--append-system-prompt").map { arguments[$0 + 1] } == "About Wicket.")
        #expect(arguments.firstIndex(of: "--permission-prompt-tool").map { arguments[$0 + 1] } == "stdio")
        // Nothing that would drop the user's settings, rules, hooks or servers, or their history.
        for flag in ["--safe-mode", "--strict-mcp-config", "--no-session-persistence", "--resume"] {
            #expect(!arguments.contains(flag), "\(flag)")
        }
        let resumed = ClaudeTranscript.arguments(for: request(resume: "s1"))
        #expect(resumed.suffix(2) == ["--resume", "s1"])

        // The prompt goes in as a user message and stdin stays open until the result.
        var transcript = ClaudeTranscript(request: request())
        let start = transcript.start()
        #expect(!start.closeInput)
        #expect(try sent(start)["message"]?["content"] == .string("Hi"))
        let end = transcript.receive(
            line(#"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1"}"#))
        #expect(end.events == [.session("s1"), .answer("ok")] && end.closeInput)
    }

    @Test func filesAndOtherToolsSayWhatTheyTouchAndCancelledPromptsGo() throws {
        var transcript = ClaudeTranscript(request: request())
        let write = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"w","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/work/notes/b.txt","content":"hi"},"tool_use_id":"t1"}}"#
            ))
        let fetch = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"f","request":{"subtype":"can_use_tool","tool_name":"WebFetch","display_name":"Fetch","input":{"url":"https://example.com","prompt":"Summarize"},"tool_use_id":"t2"}}"#
            ))
        guard case .approvals(let both)? = fetch.events.first, both.count == 2,
            case .approvals(let first)? = write.events.first
        else {
            Issue.record("no approvals: \(fetch.events)")
            return
        }
        #expect(first[0].kind == .fileChange && first[0].subject == "write notes/b.txt")
        #expect(both[1].kind == .tool && both[1].subject == "Fetch")
        #expect(both[1].input == "prompt: Summarize\nurl: https://example.com")
        // The CLI withdraws one; the other's tool result settles it.
        #expect(
            transcript.receive(line(#"{"type":"control_cancel_request","request_id":"f"}"#)).events == [
                .approvals([first[0]])
            ])
        #expect(
            transcript.receive(
                line(
                    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
                )
            ).events == [.approvals([])])
    }

    @Test func subAgentsMessagesQuestionsAndUnknownRequestsAreLeftOut() throws {
        var transcript = ClaudeTranscript(request: request())
        #expect(
            transcript.receive(
                line(
                    #"{"type":"assistant","parent_tool_use_id":"toolu_9","message":{"content":[{"type":"text","text":"sub"}]}}"#
                )
            ).events.isEmpty)
        // The palette has no form for questions: the agent asks in its reply instead.
        let question = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{}}}"#
            ))
        #expect(question.events.isEmpty)
        #expect(try sent(question)["response"]?["response"]?["behavior"] == .string("deny"))
        let hook = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"h","request":{"subtype":"hook_callback","callback_id":"x"}}"#
            ))
        #expect(hook.events.isEmpty)
        #expect(try sent(hook)["response"]?["subtype"] == .string("error"))
    }
}

/// Real processes: replies reach a waiting agent, the answer waits for the whole tree, and ending a
/// run stops what it started.
@Suite struct AgentProcessTests {
    @Test(arguments: [AgentProvider.codex, .claude])
    func aReplyReachesTheAgentWhileItWaits(provider: AgentProvider) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let replyFile = folder.appending(path: "reply")
        let script =
            switch provider {
            case .codex:
                """
                echo '{"method":"item/commandExecution/requestApproval","id":"a","params":{"command":"ls"}}'
                while read -r line; do case "$line" in *decision*) printf '%s' "$line" > '\(replyFile.path)'; break;; esac; done
                echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"ok"}}}'
                echo '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                """
            case .claude:
                """
                read -r prompt
                echo '{"type":"control_request","request_id":"a","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t"}}'
                while read -r line; do case "$line" in *control_response*) printf '%s' "$line" > '\(replyFile.path)'; break;; esac; done
                echo '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
                cat > /dev/null
                """
            }
        let run = try fakeAgent(provider, script).run(
            AgentRequest(prompt: "test", workingDirectory: folder, options: defaults))
        var last: AgentEvent?
        for await event in run {
            if case .approvals(let approvals) = event, let first = approvals.first {
                run.reply(to: first, .accept)
            }
            last = event
        }
        #expect(last == .answer("ok"))
        #expect(await run.ended == .exited(.status(0)))
        let reply = try decoded(try Data(contentsOf: replyFile))
        #expect(reply["id"] == .string("a") || reply["response"]?["request_id"] == .string("a"))
    }

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
              print q(\(claudeMessage)) . "\\n";
              sleep 60;
            ' '\(pids.path)' &
            """)
        let request = AgentRequest(
            prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, options: defaults)
        let consumer = Task {
            for await event in agent.run(request) {
                guard case .message = event else { continue }
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
        let run = AgentProcess.run(
            agent.executable, arguments: [], in: FileManager.default.temporaryDirectory,
            transcript: ClaudeTranscript(request: request()))
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
        let start = ContinuousClock.now
        let run = AgentProcess.run(
            agent.executable, arguments: [], in: FileManager.default.temporaryDirectory,
            transcript: ClaudeTranscript(request: request()),
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

    /// A child in its own session, as Codex runs commands, so a process group kill would miss it.
    @Test func cancelAndWaitReturnsOnceTheTreeIsGone() async throws {
        let pids = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/pids-\(UUID().uuidString)")
        let agent = try fakeAgent(
            .claude,
            """
            /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 60' &
            echo "$$ $!" > '\(pids.path)'
            echo '\(claudeMessage)'
            sleep 60
            """)
        let run = agent.run(
            AgentRequest(
                prompt: "test", workingDirectory: FileManager.default.temporaryDirectory, options: defaults))
        var events: [AgentEvent] = []
        for await event in run {
            events.append(event)
            if case .message = event { #expect(await run.cancelAndWait() == .terminated) }
        }
        // No final event after a cancel, and nothing left running the moment it returned.
        #expect(events == [.message("working")])
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
