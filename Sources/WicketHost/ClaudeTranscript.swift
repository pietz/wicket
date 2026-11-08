import Foundation
import WicketCore

/// Claude Code through `claude -p` with stream-json output: the prompt goes in on stdin, events come
/// out one JSON object per line, and a `result` object ends the run.
struct ClaudeTranscript: AgentTranscript {
    let request: AgentRequest
    private var newMessage = false
    private var streamed = false

    init(request: AgentRequest) {
        self.request = request
    }

    /// Bash runs in Claude Code's own sandbox: writes only inside the working directory (and temp
    /// folders), no network, and no unsandboxed fallback.
    private static let sandbox =
        #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}"#

    static func arguments(for mode: AgentMode) -> [String] {
        // --safe-mode drops the user's CLAUDE.md, hooks, plugins, skills and MCP servers;
        // --permission-prompts none denies anything that would ask.
        let common = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--permission-prompts", "none",
        ]
        switch mode {
        // Acting runs stay answer-only until the permission bridge lands.
        case .answer, .act:
            return common + ["--tools", "", "--effort", "low", "--system-prompt", Agent.answerInstructions]
        case .build:
            // --restricted confines the file tools to the working directory and ignores settings
            // files other than --settings.
            return common + [
                "--restricted", "--tools", "Read,Edit,Write,Glob,Grep,Bash", "--permission-mode",
                "acceptEdits",
                "--settings", sandbox,
            ]
        }
    }

    mutating func start() -> AgentStep {
        AgentStep(send: [Data(request.prompt.utf8)], closeInput: true)
    }

    mutating func receive(_ line: Data) -> AgentStep {
        guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: line),
            // Sub-agents' messages carry their parent tool call; only the main agent's are shown.
            message["parent_tool_use_id"] ?? .null == .null
        else { return AgentStep() }
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
            default:
                break
            }
        case "assistant":
            let calls =
                message["message"]?["content"]?.array?.filter { $0["type"]?.string == "tool_use" } ?? []
            return AgentStep(events: calls.map { .activity(Self.activity($0)) })
        case "result":
            return AgentStep(events: [Self.result(message)])
        default:
            break
        }
        return AgentStep()
    }

    private static func activity(_ call: JSONValue) -> String {
        let name = call["name"]?.string ?? "a tool"
        let input = call["input"] ?? .null
        let file = (input["file_path"]?.string).map { URL(filePath: $0).lastPathComponent } ?? ""
        switch name {
        case "Bash": return "Ran " + summarized(input["command"]?.string ?? "")
        case "Edit", "Write", "NotebookEdit": return "Edited \(file)"
        case "Read": return "Read \(file)"
        case "Glob", "Grep": return "Searched files"
        default: return "Used \(name)"
        }
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
}
