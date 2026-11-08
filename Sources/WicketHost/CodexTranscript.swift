import Foundation
import WicketCore

/// Codex through `codex app-server`: JSON-RPC over stdio (lines without the "jsonrpc" field):
/// initialize, thread/start, turn/start, then notifications until turn/completed. Approval policy,
/// sandbox, reviewer, features and MCP servers are the user's own Codex configuration; command,
/// network and file-change approvals become `AgentEvent.approvals`, answered through `reply(_:)`.
/// Threads stay in Codex's history, so Follow Up continues one with thread/resume. A resumed thread
/// keeps the policy it started with, so a resume first reads the configuration (config/read) and
/// sets the policy configured now (verified with 0.167).
struct CodexTranscript: AgentTranscript {
    let request: AgentRequest
    private var answer: String?
    private var turnError: String?
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

    mutating func start() -> AgentStep {
        AgentStep(send: [
            Self.request(
                .initialize, "initialize",
                ["clientInfo": .object(["name": .string("wicket"), "version": .string("1")])]),
            Self.line(["method": .string("initialized")]),
            request.resume == nil
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
            var params = Self.turnSettings(request.options)
            params["threadId"] = thread
            params["input"] = .array([.object(["type": .string("text"), "text": .string(request.prompt)])])
            return AgentStep(
                events: thread.string.map { [.session($0)] } ?? [],
                send: [Self.request(.startTurn, "turn/start", params)])
        case .initialize, .startTurn:
            return AgentStep()
        }
    }

    /// What turn/start sets from the user's choices.
    static func turnSettings(_ options: AgentOptions) -> [String: JSONValue] {
        [
            "model": .string(options.model), "effort": .string(options.effort),
            // "default" is standard speed even for a model whose catalog default is the fast tier.
            "serviceTierForTurn": .string(options.speed == .fast ? "priority" : "default"),
        ]
    }

    /// thread/start: a thread in the working directory, kept in Codex's history, with Wicket's
    /// instructions. Resuming sends thread/resume instead, with the instructions again, none of its
    /// old turns, and the `config`'s policy.
    private func startThread(config: JSONValue) -> Data {
        var params: [String: JSONValue] = ["cwd": .string(request.workingDirectory.path)]
        params["developerInstructions"] = request.instructions.map(JSONValue.string)
        guard let thread = request.resume else { return Self.request(.startThread, "thread/start", params) }
        params["threadId"] = .string(thread)
        params["excludeTurns"] = .bool(true)
        params["approvalPolicy"] = config["approval_policy"]
        params["sandbox"] = config["sandbox_mode"]
        params["approvalsReviewer"] = config["approvals_reviewer"]
        return Self.request(.startThread, "thread/resume", params)
    }

    /// A request from the server: a command, network or file-change approval waits for the user;
    /// anything else is refused.
    private mutating func serverRequest(_ id: JSONValue, _ method: String, _ params: JSONValue) -> AgentStep {
        let approval: AgentApproval
        switch method {
        case "item/commandExecution/requestApproval":
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
        case "item/fileChange/requestApproval":
            approval = AgentApproval(
                id: id, kind: .fileChange,
                subject: params["itemId"]?.string.flatMap { changes[$0] } ?? "files",
                reason: params["reason"]?.string, grantRoot: params["grantRoot"]?.string)
        default:
            return Self.refuse(id)
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
        case "item/started":
            if let item = params["item"], item["type"]?.string == "fileChange", let id = item["id"]?.string {
                changes[id] = changes(item)
            }
        case "item/completed":
            guard let item = params["item"], item["type"]?.string == "agentMessage",
                let text = item["text"]?.string, !text.isEmpty
            else { break }
            if item["phase"]?.string != "commentary" { answer = text }
            return AgentStep(events: [.message(text)])
        case "error":
            // Retries ("Reconnecting... 2/5") end in another error or the answer.
            if params["willRetry"] != .bool(true) { turnError = params["error"]?["message"]?.string }
        case "turn/completed":
            let turn = params["turn"] ?? .null
            switch turn["status"]?.string {
            case "completed":
                return AgentStep(events: [.answer(answer ?? "")])
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
    private static func refuse(_ id: JSONValue) -> AgentStep {
        let error = JSONValue.object([
            "code": .integer(-32601), "message": .string("Wicket does not grant requests from the agent"),
        ])
        return AgentStep(send: [line(["id": id, "error": error])])
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        Data((JSONValue.object(object).json + "\n").utf8)
    }
}

extension JSONValue {
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}
