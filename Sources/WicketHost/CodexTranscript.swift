import Foundation
import WicketCore

/// Codex through `codex app-server`: JSON-RPC over stdio (lines without the "jsonrpc" field).
///
/// Answer runs are initialize, config/read (to learn the user's MCP servers), thread/start
/// (ephemeral, read-only, approval policy "never", those servers disabled), turn/start,
/// then notifications until turn/completed; any request the server still sends is refused. Acting
/// runs leave approval policy, sandbox, reviewer, features and MCP servers to the user's own Codex
/// configuration; their command, network and file-change approvals become `AgentEvent.approvals`,
/// answered through `reply(_:)`. Their threads stay in Codex's history, so Follow Up continues one
/// with thread/resume. A resumed thread keeps the policy it started with, so a resume first reads
/// the configuration and sets the policy configured now (verified with 0.167).
struct CodexTranscript: AgentTranscript {
    let request: AgentRequest
    private var answer: String?
    private var usage: AgentUsage?
    private var turnError: String?
    private var messages = Set<String>()
    private var streamed = false
    /// Approvals waiting for the user, oldest first.
    private var pending: [AgentApproval] = []
    /// File changes by item id, as "add notes.md": a file-change approval names only its item.
    private var changes: [String: String] = [:]

    init(request: AgentRequest) {
        self.request = request
    }

    private enum ID: Int {
        case initialize = 1
        case readConfig, startThread, startTurn
    }

    /// Features switched off for answer runs: anything that reaches outside the sandbox or brings
    /// the user's own setup along (hooks, plugins, apps, browser and computer use, sub-agents,
    /// memories), the shell, and the code-mode host every other tool runs through. As `-c`
    /// overrides, because `--disable` rejects names a later version drops.
    private static let disabled = [
        "apps", "plugins", "browser_use", "computer_use", "in_app_browser", "image_generation", "hooks",
        "multi_agent", "goals", "memories", "tool_suggest", "skill_search", "default_mode_request_user_input",
        "shell_tool", "unified_exec", "code_mode_host", "js_repl", "view_image", "sleep_tool",
    ]

    /// Acting runs override nothing: the user's own Codex configuration is the policy.
    static func arguments(for mode: AgentMode) -> [String] {
        guard mode == .answer else { return ["app-server"] }
        let overrides =
            disabled.map { "features.\($0)=false" } + [
                "features.multi_agent_v2.enabled=false", "agents.enabled=false", #"web_search="disabled""#,
                "notify=[]", "skills.include_instructions=false", "include_apps_instructions=false",
            ]
        return ["app-server"] + overrides.flatMap { ["-c", $0] }
    }

    mutating func start() -> AgentStep {
        AgentStep(send: [
            Self.request(
                .initialize, "initialize",
                ["clientInfo": .object(["name": .string("wicket"), "version": .string("1")])]),
            Self.line(["method": .string("initialized")]),
            request.mode != .answer && request.resume == nil
                ? startThread(config: .null)
                : Self.request(.readConfig, "config/read", ["cwd": .string(request.workingDirectory.path)]),
        ])
    }

    /// The reply to an approval: the decision, under the request's own id.
    static func reply(_ reply: AgentReply) -> Data? {
        line([
            "id": reply.approval.id,
            "result": .object(["decision": .string(reply.decision.rawValue)]),
        ])
    }

    mutating func receive(_ line: Data) -> AgentStep {
        guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return AgentStep()
        }
        if let method = message["method"]?.string {
            if let id = message["id"] { return serverRequest(id, method, message["params"] ?? .null) }
            return notification(method, message["params"] ?? .null)
        }
        guard let id = message["id"]?.integer.flatMap(ID.init(rawValue:)) else { return AgentStep() }
        if let error = message["error"] {
            return AgentStep(events: [.error(error["message"]?.string ?? "Codex refused the request")])
        }
        return response(id, message["result"] ?? .null)
    }

    private func response(_ id: ID, _ result: JSONValue) -> AgentStep {
        switch id {
        case .readConfig:
            return AgentStep(send: [startThread(config: result["config"] ?? .null)])
        case .startThread:
            guard let thread = result["thread"]?["id"] else {
                return AgentStep(events: [.error("Codex started no thread")])
            }
            var events: [AgentEvent] = []
            var params: [String: JSONValue] = [
                "threadId": thread,
                "input": .array([.object(["type": .string("text"), "text": .string(request.prompt)])]),
            ]
            switch request.mode {
            case .answer: params["effort"] = .string("low")
            case .act(let options):
                params.merge(Self.turnSettings(options)) { $1 }
                if let id = thread.string { events.append(.session(id)) }
            }
            return AgentStep(events: events, send: [Self.request(.startTurn, "turn/start", params)])
        case .initialize, .startTurn:
            return AgentStep()
        }
    }

    /// What an acting run's turn/start sets from the user's choices.
    static func turnSettings(_ options: AgentOptions) -> [String: JSONValue] {
        [
            "model": .string(options.model), "effort": .string(options.effort),
            // "default" is standard speed even for a model whose catalog default is the fast tier.
            "serviceTierForTurn": .string(options.speed == .fast ? "priority" : "default"),
        ]
    }

    /// thread/start: a thread in the working directory. Answer runs' are ephemeral, with a read-only
    /// sandbox, approval policy "never" and the `config`'s MCP servers disabled; acting runs' are
    /// kept and get Wicket's instructions. Resuming sends thread/resume instead, with the
    /// instructions again, none of its old turns, and the `config`'s policy.
    private func startThread(config: JSONValue) -> Data {
        var params: [String: JSONValue] = ["cwd": .string(request.workingDirectory.path)]
        switch request.mode {
        case .act:
            params["developerInstructions"] = request.instructions.map(JSONValue.string)
            if let thread = request.resume {
                params["threadId"] = .string(thread)
                params["excludeTurns"] = .bool(true)
                params["approvalPolicy"] = config["approval_policy"]
                params["sandbox"] = config["sandbox_mode"]
                params["approvalsReviewer"] = config["approvals_reviewer"]
                return Self.request(.startThread, "thread/resume", params)
            }
        case .answer:
            let servers = config["mcp_servers"]?.object?.keys.sorted() ?? []
            params["ephemeral"] = .bool(true)
            let off = JSONValue.object(["enabled": .bool(false)])
            params["sandbox"] = .string("read-only")
            params["approvalPolicy"] = .string("never")
            params["config"] = .object([
                "mcp_servers": .object(Dictionary(uniqueKeysWithValues: servers.map { ($0, off) }))
            ])
            params["baseInstructions"] = .string(Agent.answerInstructions)
        }
        return Self.request(.startThread, "thread/start", params)
    }

    /// A request from the server: in an acting run, a command, network or file-change approval
    /// waits for the user; anything else is refused.
    private mutating func serverRequest(_ id: JSONValue, _ method: String, _ params: JSONValue) -> AgentStep {
        let approval: AgentApproval
        switch (request.mode, method) {
        case (.act, "item/commandExecution/requestApproval"):
            // A managed-network prompt comes as a command approval with the host it wants to reach.
            if let network = params["networkApprovalContext"], let host = network["host"]?.string {
                let via = network["protocol"]?.string.map { " (\($0))" } ?? ""
                approval = AgentApproval(
                    id: id, kind: .network, subject: host + via, reason: params["reason"]?.string)
            } else {
                approval = AgentApproval(
                    id: id, kind: .command, subject: Self.fullCommand(params) ?? "a command",
                    reason: params["reason"]?.string, workingDirectory: params["cwd"]?.string)
            }
        case (.act, "item/fileChange/requestApproval"):
            approval = AgentApproval(
                id: id, kind: .fileChange,
                subject: params["itemId"]?.string.flatMap { changes[$0] } ?? "files",
                reason: params["reason"]?.string, grantRoot: params["grantRoot"]?.string)
        default:
            return Self.refuse(id, method)
        }
        pending.append(approval)
        return AgentStep(events: [.approvals(pending)])
    }

    private mutating func notification(_ method: String, _ params: JSONValue) -> AgentStep {
        switch method {
        case "serverRequest/resolved":
            let count = pending.count
            pending.removeAll { $0.id == params["requestId"] }
            if pending.count != count { return AgentStep(events: [.approvals(pending)]) }
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.string, let item = params["itemId"]?.string else { break }
            var text = delta
            if messages.insert(item).inserted, streamed { text = "\n\n" + text }
            streamed = true
            return AgentStep(events: [.text(text)])
        case "item/started":
            if let item = params["item"], item["type"]?.string == "fileChange", let id = item["id"]?.string {
                changes[id] = changes(item)
            }
            if let activity = params["item"].flatMap(Self.activity(started:)) {
                return AgentStep(events: [.activity(activity)])
            }
        case "item/completed":
            guard let item = params["item"] else { break }
            if item["type"]?.string == "agentMessage", let text = item["text"]?.string,
                item["phase"]?.string != "commentary"
            {
                answer = text
            }
            if item["type"]?.string == "agentMessage" { return AgentStep(events: [.messageEnd]) }
            if let activity = activity(completed: item) {
                return AgentStep(events: [.activity(activity)] + (Self.acted(item) ? [.acted] : []))
            }
        case "thread/tokenUsage/updated":
            if let total = params["tokenUsage"]?["total"] {
                usage = AgentUsage(
                    inputTokens: total["inputTokens"]?.integer ?? 0,
                    cachedInputTokens: total["cachedInputTokens"]?.integer ?? 0,
                    outputTokens: total["outputTokens"]?.integer ?? 0)
            }
        case "error":
            let message = params["error"]?["message"]?.string
            // Retries ("Reconnecting... 2/5") can take many seconds, so they are shown.
            guard params["willRetry"] == .bool(true) else {
                turnError = message
                break
            }
            if let message { return AgentStep(events: [.activity(message)]) }
        case "turn/completed":
            let turn = params["turn"] ?? .null
            switch turn["status"]?.string {
            case "completed":
                return AgentStep(events: [.answer(answer ?? "", usage: usage)])
            case "interrupted":
                return AgentStep(events: [.error("Codex interrupted the turn")])
            default:
                let message =
                    turn["error"]?["message"]?.string ?? turnError ?? "Codex failed without a message"
                return AgentStep(events: [.error(message)])
            }
        default:
            break
        }
        return AgentStep()
    }

    /// A summary for tool calls worth showing when they start.
    private static func activity(started item: JSONValue) -> String? {
        switch item["type"]?.string {
        case "webSearch": return "Searched the web"
        case "mcpToolCall":
            return "Used \(item["server"]?.string ?? "?").\(item["tool"]?.string ?? "?")"
        default: return nil
        }
    }

    /// A summary for commands and file changes once done: only then is it known whether they ran.
    private func activity(completed item: JSONValue) -> String? {
        let declined = item["status"]?.string == "declined"
        switch item["type"]?.string {
        case "commandExecution":
            let command = summarized(Self.command(item) ?? "")
            return declined ? "Declined " + command : "Ran " + command
        case "fileChange":
            let names = (item["changes"]?.array ?? []).compactMap { $0["path"]?.string }.map(request.shown)
            guard !names.isEmpty, declined || item["status"]?.string == "completed" else { return nil }
            return (declined ? "Declined changes to " : "Edited ") + names.joined(separator: ", ")
        default: return nil
        }
    }

    /// Whether a completed item ran a command or changed files (declined and failed ones count only
    /// if they ran: a failed command did).
    private static func acted(_ item: JSONValue) -> Bool {
        switch (item["type"]?.string, item["status"]?.string) {
        case ("commandExecution", let status): status != "declined"
        case ("fileChange", "completed"): true
        default: false
        }
    }

    /// A command item's or approval's command, without the `zsh -lc` wrapper `commandActions` drops.
    private static func command(_ value: JSONValue) -> String? {
        value["commandActions"]?.array?.first?["command"]?.string ?? value["command"]?.string
    }

    /// An approval's whole command, as it will run: `commandActions` can hold only its first part.
    /// Unwrapped from `zsh -lc '…'` when what it wraps has no quote of its own.
    private static func fullCommand(_ params: JSONValue) -> String? {
        guard let command = params["command"]?.string else { return nil }
        if let wrapped = command.wholeMatch(of: #/\/bin\/(?:z|ba)?sh -lc '([^']*)'/#) {
            return String(wrapped.output.1)
        }
        return command
    }

    /// A file-change item's changes, such as "add notes.md, update Sources/main.swift".
    private func changes(_ item: JSONValue) -> String {
        let changes = (item["changes"]?.array ?? []).compactMap { change -> String? in
            guard let path = change["path"]?.string else { return nil }
            return (change["kind"]?["type"]?.string ?? "change") + " " + request.shown(path)
        }
        return changes.isEmpty ? "files" : changes.joined(separator: ", ")
    }

    private static func request(_ id: ID, _ method: String, _ params: [String: JSONValue]) -> Data {
        line(["id": .integer(id.rawValue), "method": .string(method), "params": .object(params)])
    }

    /// Answers a server request with an error, which Codex treats as declined.
    private static func refuse(_ id: JSONValue, _ method: String) -> AgentStep {
        let error = JSONValue.object([
            "code": .integer(-32601), "message": .string("Wicket does not grant requests from the agent"),
        ])
        return AgentStep(events: [.activity("Declined \(method)")], send: [line(["id": id, "error": error])])
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        Data((JSONValue.object(object).json + "\n").utf8)
    }
}

/// A command shortened to one line of about 80 characters.
func summarized(_ command: String) -> String {
    let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.count > 80 ? line.prefix(79) + "…" : line
}

extension JSONValue {
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}
