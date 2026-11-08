import Foundation
import WicketCore

/// Claude Code through `claude -p` with stream-json output: events come out one JSON object per
/// line, and a `result` object ends the run.
///
/// Answer runs send the prompt as plain text on stdin and close it, with every tool, customization
/// and prompt off. Acting runs keep the user's own setup (settings, permission mode and rules, hooks,
/// MCP servers, CLAUDE.md) with the model, effort and speed chosen in Settings ▸ AI, and talk
/// stream-json both ways: each permission prompt comes out as a `control_request` (`can_use_tool`)
/// that becomes an `AgentApproval`, answered by a `control_response`. Their session stays in Claude
/// Code's history, so Follow Up continues it with `--resume`, which takes the permission mode
/// configured now, not the one the session started with (verified with 2.1.319).
struct ClaudeTranscript: AgentTranscript {
    let request: AgentRequest
    private var newMessage = false
    private var streamed = false
    /// Approvals waiting for the user, oldest first, with the tool call each is for.
    private var pending: [(call: String?, approval: AgentApproval)] = []
    /// The main agent's tool calls by id, until their results say how they went.
    private var calls: [String: JSONValue] = [:]

    init(request: AgentRequest) {
        self.request = request
    }

    static func arguments(for request: AgentRequest) -> [String] {
        let output = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        switch request.mode {
        case .act(let options):
            // What would prompt comes to Wicket over stdio.
            let instructions = request.instructions.map { ["--append-system-prompt", $0] } ?? []
            return output + ["--input-format", "stream-json", "--permission-prompt-tool", "stdio"]
                + instructions + settings(options) + (request.resume.map { ["--resume", $0] } ?? [])
        case .answer:
            // --safe-mode drops the user's CLAUDE.md, hooks, plugins, skills and MCP servers;
            // --permission-prompts none denies anything that would ask.
            return output + [
                "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--permission-prompts",
                "none", "--tools", "",
                "--effort", "low", "--system-prompt", Agent.answerInstructions,
            ]
        }
    }

    /// The flags for the user's choices. With `-p`, fast mode is on only when `--settings` opts in,
    /// so regular needs nothing (2.1.318).
    static func settings(_ options: AgentOptions) -> [String] {
        let flags = ["--model", options.model, "--effort", options.effort]
        return options.speed == .fast ? flags + ["--settings", #"{"fastMode":true}"#] : flags
    }

    mutating func start() -> AgentStep {
        guard request.mode != .answer else {
            return AgentStep(send: [Data(request.prompt.utf8)], closeInput: true)
        }
        return AgentStep(send: [
            Self.line([
                "type": .string("user"),
                "message": .object(["role": .string("user"), "content": .string(request.prompt)]),
                "parent_tool_use_id": .null,
                "session_id": .string("default"),
            ])
        ])
    }

    /// The answer to a permission prompt: an allow sends the tool's input back unchanged and grants
    /// nothing beyond this call.
    static func reply(_ reply: AgentReply) -> Data? {
        let id = reply.approval.id
        guard let requestID = id["request_id"] else { return nil }
        switch reply.decision {
        case .accept:
            return response(
                requestID, ["behavior": .string("allow"), "updatedInput": id["input"] ?? .object([:])])
        case .decline: return response(requestID, deny)
        }
    }

    private static let deny: [String: JSONValue] = [
        "behavior": .string("deny"), "message": .string("The user declined this in Wicket."),
    ]

    private static func response(_ requestID: JSONValue, _ decision: [String: JSONValue]) -> Data {
        line([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"), "request_id": requestID, "response": .object(decision),
            ]),
        ])
    }

    mutating func receive(_ line: Data) -> AgentStep {
        guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return AgentStep()
        }
        switch message["type"]?.string {
        // Prompts and results come for sub-agents' tools too: those go to the user like any other.
        case "control_request":
            return controlRequest(message["request_id"] ?? .null, message["request"] ?? .null)
        case "control_cancel_request":
            return resolve { $0.approval.id["request_id"] == message["request_id"] }
        case "user":
            return results(message["message"]?["content"]?.array ?? [], meta: message["tool_result_meta"])
        case "assistant":
            // Every agent's calls, sub-agents' included, so what they did counts as acting.
            for call in message["message"]?["content"]?.array ?? [] where call["type"]?.string == "tool_use" {
                if let id = call["id"]?.string { calls[id] = call }
            }
        default:
            break
        }
        // Sub-agents' messages carry their parent tool call; only the main agent's are shown.
        guard message["parent_tool_use_id"] ?? .null == .null else { return AgentStep() }
        switch message["type"]?.string {
        case "stream_event":
            let event = message["event"] ?? .null
            switch event["type"]?.string {
            case "message_start":
                newMessage = true
            case "content_block_delta":
                guard event["delta"]?["type"]?.string == "text_delta",
                    let delta = event["delta"]?["text"]?.string
                else { break }
                let text = newMessage && streamed ? "\n\n" + delta : delta
                newMessage = false
                streamed = true
                return AgentStep(events: [.text(text)])
            case "message_stop" where streamed && !newMessage:
                return AgentStep(events: [.messageEnd])
            default:
                break
            }
        case "result":
            // With stream-json input the CLI waits for more until stdin closes.
            guard request.mode != .answer else { return AgentStep(events: [Self.result(message)]) }
            let session = message["session_id"]?.string.map { [AgentEvent.session($0)] } ?? []
            return AgentStep(events: session + [Self.result(message)], closeInput: true)
        default:
            break
        }
        return AgentStep()
    }

    /// A request from the CLI: in an acting run, a permission prompt waits for the user; anything
    /// else is refused (Wicket registers no hooks or SDK servers, so none should come).
    private mutating func controlRequest(_ id: JSONValue, _ body: JSONValue) -> AgentStep {
        guard request.mode != .answer, body["subtype"]?.string == "can_use_tool",
            let tool = body["tool_name"]?.string
        else {
            return AgentStep(send: [
                Self.refusal(id, "Wicket does not handle \(body["subtype"]?.string ?? "this")")
            ])
        }
        let input = body["input"] ?? .object([:])
        // Questions need a form Wicket doesn't have; the agent can ask in its reply instead.
        if tool == "AskUserQuestion" {
            return AgentStep(
                events: [.activity("Declined a question")], send: [Self.response(id, Self.deny)])
        }
        let approvalID = JSONValue.object(["request_id": id, "input": input])
        let name = body["display_name"]?.string ?? tool
        let reason = body["decision_reason"]?.string
        let approval: AgentApproval
        switch tool {
        case "Bash":
            approval = AgentApproval(
                id: approvalID, kind: .command, subject: input["command"]?.string ?? "a command",
                // No folder: Claude Code's shell keeps its `cd`s and the prompt doesn't say where it is.
                reason: input["description"]?.string ?? reason)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] ?? input["notebook_path"])?.string
            approval = AgentApproval(
                id: approvalID, kind: .fileChange,
                subject: path.map { (tool == "Write" ? "write " : "edit ") + request.shown($0) } ?? "files",
                reason: reason)
        default:
            approval = AgentApproval(
                id: approvalID, kind: .tool, subject: name, reason: reason,
                input: Self.brief(input))
        }
        pending.append((body["tool_use_id"]?.string, approval))
        return AgentStep(events: [.approvals(pending.map(\.approval))])
    }

    /// Tool results: each settles its call's approval, if one waits, and says what the call did.
    private mutating func results(_ content: [JSONValue], meta: JSONValue?) -> AgentStep {
        var step = AgentStep()
        let count = pending.count
        for result in content where result["type"]?.string == "tool_result" {
            guard let id = result["tool_use_id"]?.string else { continue }
            pending.removeAll { $0.call == id }
            guard let call = calls.removeValue(forKey: id) else { continue }
            let rejected =
                meta?.array?.contains {
                    $0["id"]?.string == id && $0["permission_decision"]?["decision"]?.string == "reject"
                } ?? false
            step.events.append(.activity(activity(call, declined: rejected)))
            if !rejected, !Self.readOnly.contains(call["name"]?.string ?? "") {
                step.events.append(.acted)
            }
        }
        if pending.count != count { step.events.insert(.approvals(pending.map(\.approval)), at: 0) }
        return step
    }

    /// Tools known not to change anything; any other call (MCP tools included) counts as acting.
    static let readOnly: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoWrite", "Task", "Agent", "ToolSearch",
        "AskUserQuestion", "ExitPlanMode", "BashOutput",
    ]

    private mutating func resolve(_ matches: ((call: String?, approval: AgentApproval)) -> Bool) -> AgentStep
    {
        let count = pending.count
        pending.removeAll(where: matches)
        return pending.count == count ? AgentStep() : AgentStep(events: [.approvals(pending.map(\.approval))])
    }

    private func activity(_ call: JSONValue, declined: Bool) -> String {
        let name = call["name"]?.string ?? "a tool"
        let input = call["input"] ?? .null
        let file = (input["file_path"] ?? input["notebook_path"])?.string.map(request.shown) ?? ""
        switch name {
        case "Bash": return (declined ? "Declined " : "Ran ") + summarized(input["command"]?.string ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return declined ? "Declined changes to \(file)" : "Edited \(file)"
        case "Read": return "Read \(file)"
        case "Glob", "Grep": return "Searched files"
        default: return (declined ? "Declined " : "Used ") + name
        }
    }

    /// A tool's input as at most six `key: value` lines, each value on one line of about 80
    /// characters.
    static func brief(_ input: JSONValue) -> String? {
        guard let object = input.object, !object.isEmpty else { return nil }
        let lines = object.keys.sorted().prefix(6).map { key in
            let value = object[key]?.string ?? object[key]?.json ?? ""
            return key + ": " + summarized(value)
        }
        return (lines + (object.count > 6 ? ["…"] : [])).joined(separator: "\n")
    }

    private static func result(_ message: [String: JSONValue]) -> AgentEvent {
        let text = message["result"]?.string ?? ""
        guard message["subtype"]?.string == "success", message["is_error"] != .bool(true) else {
            let errors = message["errors"]?.array?.compactMap(\.string) ?? []
            let reason = [text].filter { !$0.isEmpty } + errors
            return .error(
                reason.isEmpty
                    ? "Claude Code failed (\(message["subtype"]?.string ?? "no result"))"
                    : reason.joined(separator: " "))
        }
        let usage = message["usage"].map { usage in
            let fresh = usage["input_tokens"]?.integer ?? 0
            let written = usage["cache_creation_input_tokens"]?.integer ?? 0
            let cached = usage["cache_read_input_tokens"]?.integer ?? 0
            return AgentUsage(
                inputTokens: fresh + written + cached, cachedInputTokens: cached,
                outputTokens: usage["output_tokens"]?.integer ?? 0)
        }
        return .answer(text, usage: usage)
    }

    private static func refusal(_ id: JSONValue, _ error: String) -> Data {
        line([
            "type": .string("control_response"),
            "response": .object(["subtype": .string("error"), "request_id": id, "error": .string(error)]),
        ])
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        Data((JSONValue.object(object).json + "\n").utf8)
    }
}
