import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The agents here are shell scripts standing in for `codex` and `claude`. Most replay streams recorded
// from the real CLIs (Fixtures/, scrubbed of personal paths and account details; the Codex recordings
// were made before the adapter read the config, so their config/read reply is trimmed by hand).

extension AgentMode {
    /// An acting run with Claude's defaults on Auto, for tests where the choices don't matter.
    static let acting = AgentMode.act(
        AgentConfiguration(options: AgentProvider.claude.defaultOptions, permission: .auto))
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

    @Test func actingRunsKeepTheUsersServersAndSetTheChoicesOnTheTurn() throws {
        #expect(CodexTranscript.arguments(for: .acting) == ["app-server"])
        var transcript = CodexTranscript(
            request: AgentRequest(
                prompt: "Tidy up", workingDirectory: URL(filePath: "/tmp/work"), mode: .acting)
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
        // The choices from Settings ▸ AI (`AgentSettingsTests`).
        #expect(turn["params"]?["effort"] == .string("medium"))
        #expect(turn["params"]?["sandboxPolicy"] == .object(["type": .string("workspaceWrite")]))
    }

    @Test func approvalsWaitForTheUserUntilResolved() throws {
        var transcript = CodexTranscript(
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/work"), mode: .acting))
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
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/work"), mode: .acting))
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
            request: AgentRequest(prompt: "Hi", workingDirectory: URL(filePath: "/tmp/a"), mode: .acting))
        let step = transcript.receive(
            line(#"{"id":5,"method":"item/tool/requestUserInput","params":{"questions":[]}}"#))
        #expect(step.events == [.activity("Declined item/tool/requestUserInput")])
        #expect(try sent(step)["error"]?["code"] == .integer(-32601))
    }

    @Test func aRecordedApprovalRoundTrip() async throws {
        // Recorded from Codex 0.167 with a temporary config (on-request, read-only), the command
        // accepted; the replay ignores what it is sent.
        let events = await events(try replaying(.codex, "codex-act-approval"), .acting)
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
        let run = agent.run(AgentRequest(prompt: "test", workingDirectory: folder, mode: .acting))
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

    @Test func toolRunReportsActivityOnceEachCallHasItsResult() async throws {
        let events = await events(try replaying(.claude, "claude-build"))
        #expect(
            activities(events) == [
                "Edited /tmp/wicket-agent/stage/hello.txt", "Ran cat hello.txt && touch ../escape-bash.txt",
            ])
        // Both ran (the command failed, which still counts).
        #expect(events.filter { $0 == .acted }.count == 2)
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

    @Test func answerRunsSendThePromptAsTextWithEverythingOff() async throws {
        // Echoes its stdin back as a text delta, then succeeds.
        let agent = try fakeAgent(
            .claude,
            #"""
            prompt=$(cat)
            printf '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$prompt"
            echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
            """#)
        #expect(await events(agent).first == .text("test"))

        let answer = ClaudeTranscript.arguments(for: request(.answer))
        #expect(answer.firstIndex(of: "--tools").map { answer[$0 + 1] } == "")
        #expect(answer.contains("--safe-mode") && answer.contains("--strict-mcp-config"))
        #expect(answer.firstIndex(of: "--permission-prompts").map { answer[$0 + 1] } == "none")
    }

    @Test func actingRunsKeepTheUsersSetupAndTalkStreamJSON() throws {
        let acting = request(.acting, instructions: "About Wicket.")
        let arguments = ClaudeTranscript.arguments(for: acting)
        // Nothing that overrides the user's settings, tools or MCP servers; the model, effort and
        // permission mode are the choices from Settings ▸ AI (`AgentSettingsTests`).
        for flag in [
            "--safe-mode", "--restricted", "--strict-mcp-config", "--permission-prompts", "--tools",
            "--system-prompt", "--settings", "--setting-sources",
        ] {
            #expect(!arguments.contains(flag), "\(flag)")
        }
        #expect(arguments.firstIndex(of: "--input-format").map { arguments[$0 + 1] } == "stream-json")
        #expect(arguments.firstIndex(of: "--permission-prompt-tool").map { arguments[$0 + 1] } == "stdio")
        #expect(
            arguments.firstIndex(of: "--append-system-prompt").map { arguments[$0 + 1] }
                == Agent.actInstructions + "\n\nAbout Wicket.")

        var transcript = ClaudeTranscript(request: acting)
        let start = transcript.start()
        #expect(!start.closeInput)
        #expect(
            try decoded(try #require(start.send.first))
                == .object([
                    "type": .string("user"),
                    "message": .object(["role": .string("user"), "content": .string("Hi")]),
                    "parent_tool_use_id": .null, "session_id": .string("default"),
                ]))
        // Stdin stays open until the result, then closes so the CLI exits.
        let end = transcript.receive(
            line(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#))
        #expect(end.events == [.answer("ok", usage: nil)])
        #expect(end.closeInput)
    }

    // The control requests below are as Claude Code 2.1.318 sent them (paths shortened).

    @Test func permissionPromptsWaitForTheUserUntilTheirToolsReturn() throws {
        var transcript = ClaudeTranscript(request: request(.acting))
        _ = transcript.receive(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo one > a.txt","description":"Write \"one\" to a.txt"}}]},"parent_tool_use_id":null}"#
            ))
        let bash = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"echo one > a.txt","description":"Write \"one\" to a.txt"},"description":"Write \"one\" to a.txt","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo one *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/work"],"destination":"session"}],"blocked_path":"/tmp/work/a.txt","tool_use_id":"toolu_1"}}"#
            ))
        guard case .approvals(let first)? = bash.events.first, let command = first.first else {
            Issue.record("no approval: \(bash.events)")
            return
        }
        #expect(command.kind == .command)
        #expect(command.subject == "echo one > a.txt")
        // What Allow for Session grants beyond this call is spelled out; no folder is claimed,
        // since Claude Code's shell keeps its `cd`s.
        #expect(
            command.reason
                == "Write \"one\" to a.txt\n\nAllow for Session also allows, until this run ends: Bash(echo one *), files in /tmp/work."
        )
        #expect(command.workingDirectory == nil)
        #expect(bash.send.isEmpty)

        _ = transcript.receive(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Write","input":{"file_path":"/tmp/work/notes/b.txt","content":"hi"}}]},"parent_tool_use_id":null}"#
            ))
        let write = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/work/notes/b.txt","content":"hi"},"description":"b.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_2"}}"#
            ))
        guard case .approvals(let both)? = write.events.first, both.count == 2 else {
            Issue.record("no second approval: \(write.events)")
            return
        }
        #expect(both[1].kind == .fileChange)
        #expect(both[1].subject == "write notes/b.txt")
        // A suggested mode change (accept every edit) is never offered or applied.
        #expect(both[1].reason == nil)
        let session = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: both[1], decision: .acceptForSession))))
        #expect(session["response"]?["response"]?["updatedPermissions"] == .array([]))

        // Allow echoes the input; for the session, every suggestion stays in this session (as
        // suggested, the rule would be saved to the folder's .claude/settings.local.json).
        let allowed = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: command, decision: .acceptForSession))))
        #expect(allowed["type"] == .string("control_response"))
        #expect(allowed["response"]?["subtype"] == .string("success"))
        #expect(allowed["response"]?["request_id"] == .string("r1"))
        let decision = try #require(allowed["response"]?["response"])
        #expect(decision["behavior"] == .string("allow"))
        #expect(decision["updatedInput"]?["command"] == .string("echo one > a.txt"))
        #expect(
            decision["updatedPermissions"]?.array?.map { $0["destination"] } == [
                .string("session"), .string("session"),
            ])
        #expect(decision["updatedPermissions"]?.array?.first?["rules"]?.array?.count == 1)
        let once = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: command, decision: .accept))))
        #expect(once["response"]?["response"]?["updatedPermissions"] == nil)
        let denied = try decoded(
            try #require(ClaudeTranscript.reply(AgentReply(approval: both[1], decision: .decline))))
        #expect(denied["response"]?["request_id"] == .string("r2"))
        #expect(denied["response"]?["response"]?["behavior"] == .string("deny"))
        #expect(denied["response"]?["response"]?["interrupt"] == nil)

        // The command ran: its approval goes, then what it did.
        #expect(
            transcript.receive(
                line(
                    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok","is_error":false}]},"parent_tool_use_id":null,"tool_result_meta":[{"id":"toolu_1","permission_decision":{"decision":"accept","source":"user"}}]}"#
                )
            ).events == [.approvals([both[1]]), .activity("Ran echo one > a.txt"), .acted])
        // The write was denied: nothing acted.
        #expect(
            transcript.receive(
                line(
                    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user declined this in Wicket.","is_error":true,"tool_use_id":"toolu_2"}]},"parent_tool_use_id":null,"tool_result_meta":[{"id":"toolu_2","non_execution_kind":"permission-rule","permission_decision":{"decision":"reject","source":"user_reject"}}]}"#
                )
            ).events == [.approvals([]), .activity("Declined changes to notes/b.txt")])
    }

    @Test func subAgentsAndUnknownToolsCountAsActing() {
        var transcript = ClaudeTranscript(request: request(.acting))
        _ = transcript.receive(
            line(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_s","name":"Write","input":{"file_path":"/tmp/work/a.txt","content":"x"}},{"type":"tool_use","id":"toolu_m","name":"mcp__notes__update","input":{}},{"type":"tool_use","id":"toolu_r","name":"Read","input":{"file_path":"/tmp/work/a.txt"}}]},"parent_tool_use_id":"toolu_task"}"#
            ))
        let done = transcript.receive(
            line(
                #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_s","type":"tool_result","content":"ok"},{"tool_use_id":"toolu_m","type":"tool_result","content":"ok"},{"tool_use_id":"toolu_r","type":"tool_result","content":"x"}]},"parent_tool_use_id":"toolu_task"}"#
            ))
        #expect(done.events.filter { $0 == .acted }.count == 2)
    }

    @Test func otherToolsShowTheirInputAndCancelledPromptsGo() throws {
        var transcript = ClaudeTranscript(request: request(.acting))
        let fetch = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"WebFetch","display_name":"Fetch","input":{"url":"https://example.com","prompt":"Summarize"},"tool_use_id":"toolu_3"}}"#
            ))
        guard case .approvals(let approvals)? = fetch.events.first, let approval = approvals.first else {
            Issue.record("no approval: \(fetch.events)")
            return
        }
        #expect(approval.kind == .tool)
        #expect(approval.subject == "Fetch")
        #expect(approval.input == "prompt: Summarize\nurl: https://example.com")
        #expect(
            transcript.receive(line(#"{"type":"control_cancel_request","request_id":"r3"}"#)).events == [
                .approvals([])
            ])
    }

    @Test func questionsAndUnknownRequestsAreRefused() throws {
        var transcript = ClaudeTranscript(request: request(.acting))
        let question = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]},"tool_use_id":"toolu_q"}}"#
            ))
        #expect(question.events == [.activity("Declined a question")])
        #expect(
            try decoded(try #require(question.send.first))["response"]?["response"]?["behavior"]
                == .string("deny"))

        let hook = transcript.receive(
            line(
                #"{"type":"control_request","request_id":"h","request":{"subtype":"hook_callback","callback_id":"x"}}"#
            ))
        #expect(hook.events.isEmpty)
        #expect(try decoded(try #require(hook.send.first))["response"]?["subtype"] == .string("error"))

        // An answer run never asks: anything that comes is refused.
        var answering = ClaudeTranscript(request: request(.answer))
        let refused = answering.receive(
            line(
                #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
            ))
        #expect(refused.events.isEmpty)
        #expect(try decoded(try #require(refused.send.first))["response"]?["subtype"] == .string("error"))
    }

    @Test func aReplyReachesTheAgentWhileItWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/claude-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let replyFile = folder.appending(path: "reply")
        // Reads the prompt, asks, waits for the answer, then succeeds and waits for stdin to close.
        let agent = try fakeAgent(
            .claude,
            """
            read -r prompt
            echo '{"type":"control_request","request_id":"a","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t"}}'
            while read -r line; do case "$line" in *control_response*) printf '%s' "$line" > '\(replyFile.path)'; break;; esac; done
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
            cat > /dev/null
            """)
        let run = agent.run(AgentRequest(prompt: "test", workingDirectory: folder, mode: .acting))
        var last: AgentEvent?
        for await event in run {
            if case .approvals(let approvals) = event, let first = approvals.first {
                run.reply(to: first, .accept)
            }
            last = event
        }
        #expect(last == .answer("ok", usage: nil))
        #expect(await run.ended == .exited(.status(0)))
        let reply = try decoded(try Data(contentsOf: replyFile))
        #expect(reply["response"]?["request_id"] == .string("a"))
        #expect(reply["response"]?["response"]?["updatedInput"] == .object(["command": .string("ls")]))
    }

    /// The real CLI, on the user's subscription and settings (read, never changed): asked to write
    /// a file in a throwaway folder, with prompts forced on for this run alone (`--permission-mode
    /// manual`, since the user's mode may approve it silently). Allowed for the session, the file is
    /// written and no settings file appears in the folder. Opt in with `WICKET_TEST_CLAUDE=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_TEST_CLAUDE"] == "1"))
    func aLivePermissionPromptRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/claude-live-\(UUID().uuidString)"
        )
        .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let agent = try #require(await Agent.locate(.claude))
        let request = AgentRequest(
            prompt: "Run exactly this with the Bash tool: echo hi > hello.txt. Then reply: done.",
            workingDirectory: folder, mode: .acting)
        let run = AgentProcess.run(
            agent.executable,
            arguments: ClaudeTranscript.arguments(for: request) + [
                "--permission-mode", "manual", "--effort", "low",
            ],
            request: request, transcript: ClaudeTranscript(request: request))
        var events: [AgentEvent] = []
        for await event in run {
            if case .approvals(let approvals) = event, let first = approvals.first {
                run.reply(to: first, .acceptForSession)
            }
            events.append(event)
        }
        print("EVENTS: \(events)")
        #expect(
            events.contains { if case .approvals(let a) = $0 { a.first?.kind == .command } else { false } })
        #expect(events.contains(.acted))
        guard case .answer? = events.last else {
            Issue.record("no answer")
            return
        }
        #expect(await run.ended == .exited(.status(0)))
        #expect(try String(contentsOf: folder.appending(path: "hello.txt"), encoding: .utf8) == "hi\n")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".claude").path))
    }

    private func request(_ mode: AgentMode, instructions: String? = nil) -> AgentRequest {
        AgentRequest(
            prompt: "Hi", workingDirectory: URL(filePath: "/tmp/work"), mode: mode, instructions: instructions
        )
    }

    private func line(_ text: String) -> Data { Data(text.utf8) }

    private func decoded(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
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
