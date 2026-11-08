import Foundation
import WicketCore

/// Claude Code through `claude -p`, stream-json both ways: the prompt goes in as a user message and
/// stdin stays open until the `result` that ends the run. The user's own setup applies (settings,
/// permission mode and rules, hooks, MCP servers, CLAUDE.md) with the model, effort and speed chosen
/// in Settings ▸ AI; each permission prompt comes out as a `control_request` (`can_use_tool`) that
/// becomes an `AgentApproval`, answered by a `control_response`. The session stays in Claude Code's
/// history, so Follow Up continues it with `--resume`, which takes the permission mode configured
/// now, not the one the session started with (verified with 2.1.319).
struct ClaudeTranscript: AgentTranscript {
    let request: AgentRequest
    /// Approvals waiting for the user, oldest first, with the tool call each is for.
    private var pending: [(call: String?, approval: AgentApproval)] = []

    init(request: AgentRequest) {
        self.request = request
    }

    /// What would prompt comes to Wicket over stdio.
    static func arguments(for request: AgentRequest) -> [String] {
        [
            "-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--permission-prompt-tool", "stdio",
        ] + (request.instructions.map { ["--append-system-prompt", $0] } ?? []) + settings(request.options)
            + (request.resume.map { ["--resume", $0] } ?? [])
    }

    /// The flags for the user's choices. With `-p`, fast mode is on only when `--settings` opts in,
    /// so regular needs nothing (2.1.318).
    static func settings(_ options: AgentOptions) -> [String] {
        let flags = ["--model", options.model, "--effort", options.effort]
        return options.speed == .fast ? flags + ["--settings", #"{"fastMode":true}"#] : flags
    }

    mutating func start() -> AgentStep {
        AgentStep(send: [
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
            // A tool's result settles its call's approval, if one waits.
            let results = (message["message"]?["content"]?.array ?? []).compactMap {
                $0["type"]?.string == "tool_result" ? $0["tool_use_id"]?.string : nil
            }
            return resolve { $0.call.map(results.contains) ?? false }
        // Sub-agents' messages carry their parent tool call; only the main agent's are shown.
        case "assistant" where message["parent_tool_use_id"] ?? .null == .null:
            let text = (message["message"]?["content"]?.array ?? []).compactMap {
                $0["type"]?.string == "text" ? $0["text"]?.string : nil
            }.joined()
            return text.isEmpty ? AgentStep() : AgentStep(events: [.message(text)])
        case "result":
            // With stream-json input the CLI waits for more until stdin closes.
            let session = message["session_id"]?.string.map { [AgentEvent.session($0)] } ?? []
            return AgentStep(events: session + [Self.result(message)], closeInput: true)
        default:
            return AgentStep()
        }
    }

    /// A request from the CLI: a permission prompt waits for the user; anything else is refused
    /// (Wicket registers no hooks or SDK servers, so none should come).
    private mutating func controlRequest(_ id: JSONValue, _ body: JSONValue) -> AgentStep {
        guard body["subtype"]?.string == "can_use_tool",
            let tool = body["tool_name"]?.string
        else {
            return AgentStep(send: [
                Self.refusal(id, "Wicket does not handle \(body["subtype"]?.string ?? "this")")
            ])
        }
        let input = body["input"] ?? .object([:])
        // Questions need a form Wicket doesn't have; the agent can ask in its reply instead.
        if tool == "AskUserQuestion" {
            return AgentStep(send: [Self.response(id, Self.deny)])
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

    private mutating func resolve(_ matches: ((call: String?, approval: AgentApproval)) -> Bool) -> AgentStep
    {
        let count = pending.count
        pending.removeAll(where: matches)
        return pending.count == count ? AgentStep() : AgentStep(events: [.approvals(pending.map(\.approval))])
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
        return .answer(text)
    }

    private static func refusal(_ id: JSONValue, _ error: String) -> Data {
        line([
            "type": .string("control_response"),
            "response": .object(["subtype": .string("error"), "request_id": id, "error": .string(error)]),
        ])
    }
}

/// A command shortened to one line of about 80 characters.
private func summarized(_ command: String) -> String {
    let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.count > 80 ? line.prefix(79) + "…" : line
}
