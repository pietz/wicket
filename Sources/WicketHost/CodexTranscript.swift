import Foundation
import WicketCore

/// Codex through `codex app-server`: JSON-RPC over stdio (lines without the "jsonrpc" field).
///
/// The run is initialize, config/read (to learn the user's MCP servers), thread/start (ephemeral,
/// sandboxed, with those servers disabled), turn/start, then notifications until turn/completed.
/// Approvals never reach Wicket (the approval policy is "never"); any request the server still sends
/// is refused.
struct CodexTranscript: AgentTranscript {
    let request: AgentRequest
    private var answer: String?
    private var usage: AgentUsage?
    private var turnError: String?
    private var messages = Set<String>()
    private var streamed = false

    init(request: AgentRequest) {
        self.request = request
    }

    private enum ID: Int {
        case initialize = 1
        case readConfig, startThread, startTurn
    }

    /// Features switched off for every run: anything that reaches outside the sandbox or brings the
    /// user's own setup along (hooks, plugins, apps, browser and computer use, sub-agents, memories).
    /// As `-c` overrides, because `--disable` rejects names a later version drops.
    private static let disabled = [
        "apps", "plugins", "browser_use", "computer_use", "in_app_browser", "image_generation", "hooks",
        "multi_agent", "goals", "memories", "tool_suggest", "skill_search", "default_mode_request_user_input",
    ]
    /// Also off for answer runs: the shell, and the code-mode host every other tool runs through.
    private static let answerDisabled = [
        "shell_tool", "unified_exec", "code_mode_host", "js_repl", "view_image", "sleep_tool",
    ]

    static func arguments(for mode: AgentMode) -> [String] {
        let features = disabled + (mode == .answer ? answerDisabled : [])
        let overrides =
            features.map { "features.\($0)=false" } + [
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
            Self.request(.readConfig, "config/read", ["cwd": .string(request.workingDirectory.path)]),
        ])
    }

    mutating func receive(_ line: Data) -> AgentStep {
        guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return AgentStep()
        }
        if let method = message["method"]?.string {
            if let id = message["id"] { return Self.refuse(id, method) }
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
            // The user's MCP servers stay off: nothing from their setup runs outside the sandbox.
            let servers = result["config"]?["mcp_servers"]?.object?.keys.sorted() ?? []
            let off = JSONValue.object(["enabled": .bool(false)])
            var params: [String: JSONValue] = [
                "cwd": .string(request.workingDirectory.path),
                "sandbox": .string(request.mode == .build ? "workspace-write" : "read-only"),
                "approvalPolicy": .string("never"),
                "ephemeral": .bool(true),
                "config": .object([
                    "mcp_servers": .object(Dictionary(uniqueKeysWithValues: servers.map { ($0, off) }))
                ]),
            ]
            if request.mode == .answer { params["baseInstructions"] = .string(Agent.answerInstructions) }
            return AgentStep(send: [Self.request(.startThread, "thread/start", params)])
        case .startThread:
            guard let thread = result["thread"]?["id"] else {
                return AgentStep(events: [.error("Codex started no thread")])
            }
            var params: [String: JSONValue] = [
                "threadId": thread,
                "input": .array([.object(["type": .string("text"), "text": .string(request.prompt)])]),
            ]
            switch request.mode {
            case .answer:
                params["effort"] = .string("low")
            case .plan:
                params["sandboxPolicy"] = .object([
                    "type": .string("readOnly"), "networkAccess": .bool(false),
                ])
            case .build:
                params["sandboxPolicy"] = .object([
                    "type": .string("workspaceWrite"), "networkAccess": .bool(false),
                    "writableRoots": .array([]),
                ])
            }
            return AgentStep(send: [Self.request(.startTurn, "turn/start", params)])
        case .initialize, .startTurn:
            return AgentStep()
        }
    }

    private mutating func notification(_ method: String, _ params: JSONValue) -> AgentStep {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.string, let item = params["itemId"]?.string else { break }
            var text = delta
            if messages.insert(item).inserted, streamed { text = "\n\n" + text }
            streamed = true
            return AgentStep(events: [.text(text)])
        case "item/started":
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
            if let activity = Self.activity(completed: item) {
                return AgentStep(events: [.activity(activity)])
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
        case "commandExecution":
            // commandActions holds the command without the `zsh -lc` wrapper.
            let command =
                item["commandActions"]?.array?.first?["command"]?.string ?? item["command"]?.string ?? ""
            return "Ran " + summarized(command)
        case "webSearch": return "Searched the web"
        case "mcpToolCall":
            return "Used \(item["server"]?.string ?? "?").\(item["tool"]?.string ?? "?")"
        default: return nil
        }
    }

    /// A summary for tool calls worth showing once they are done.
    private static func activity(completed item: JSONValue) -> String? {
        guard item["type"]?.string == "fileChange", item["status"]?.string == "completed",
            let changes = item["changes"]?.array
        else { return nil }
        let names = changes.compactMap { $0["path"]?.string }.map { URL(filePath: $0).lastPathComponent }
        return names.isEmpty ? nil : "Edited " + names.joined(separator: ", ")
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
