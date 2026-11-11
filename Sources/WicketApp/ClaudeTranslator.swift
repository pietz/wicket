import Foundation

/// Claude Code through `claude -p`, stream-json both ways (verified with 2.1.321). The settings are
/// flags, so a change starts a new process that continues the session with `--resume`. A prompt
/// goes in as a user message; text arrives as partial-message deltas; each permission question is a
/// `can_use_tool` control request answered by a control response; cancel is an `interrupt` request.
/// Wicket's instructions are appended to the system prompt on every turn, so compaction keeps them.
/// The user's own Claude Code setup (rules, hooks, MCP servers, CLAUDE.md) applies.
struct ClaudeTranslator: Translator {
  static let name = "Claude Code"
  /// Open permission questions by request ID, with the tool input an allow must echo back.
  private var pending: [JSONValue: JSONValue] = [:]
  private var cancelling = false
  /// The CLI answered that it is not signed in; the turn's result says so in its own words.
  private var signedOut = false

  static func arguments(for settings: AgentConfiguration, resume: String?, instructions: String)
    -> [String]
  {
    var arguments = [
      "-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
      "--include-partial-messages", "--permission-prompt-tool", "stdio",
      "--permission-mode", settings.permissionMode, "--model", settings.model ?? "sonnet",
      "--effort", settings.effort ?? "low",
    ]
    // With -p, fast mode is on only when --settings opts in.
    if settings.speed == "on" { arguments += ["--settings", #"{"fastMode":true}"#] }
    // Every turn, not just the first: Claude rebuilds its system prompt from the current process when it
    // compacts a resumed session. It is system prompt, never history, so it does not pile up.
    arguments += ["--append-system-prompt", instructions]
    if let resume { arguments += ["--resume", resume] }
    return arguments
  }

  /// The stream-json `initialize` request lists the models without a model call. Safe mode keeps
  /// hooks, plugins and MCP servers from starting just for that.
  static let listing = Listing(
    arguments: [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--no-session-persistence", "--safe-mode",
    ],
    send: [
      .object(
        "type", .string("control_request"), "request_id", .string("models"),
        "request", .object("subtype", .string("initialize")))
    ],
    models: { message in
      guard message["type"].string == "control_response",
        message["response"]["request_id"].string == "models"
      else { return nil }
      return message["response"]["response"]["models"].array.compactMap { model in
        guard let id = model["value"].string, id != "default" else { return nil }
        return AgentModel(
          id: id, name: model["displayName"].string,
          efforts: model["supportedEffortLevels"].array.compactMap(\.string),
          fast: model["supportsFastMode"].bool)
      }
    })

  /// Tools that read or change files, with the input keys that name the files.
  private static let files: [String: (kind: AgentPermission.Kind, keys: [String])] = [
    "Write": (.edit, ["file_path"]), "Edit": (.edit, ["file_path"]),
    "MultiEdit": (.edit, ["file_path"]), "NotebookEdit": (.edit, ["notebook_path"]),
    "Read": (.read, ["file_path"]), "NotebookRead": (.read, ["notebook_path"]),
    "Glob": (.read, ["path"]), "Grep": (.read, ["path"]), "LS": (.read, ["path"]),
  ]

  mutating func start() -> Step { Step() }

  mutating func prompt(_ text: String, settings: AgentConfiguration) -> Step {
    cancelling = false
    return Step(send: [
      .object(
        "type", .string("user"),
        "message", .object("role", .string("user"), "content", .string(text)),
        "parent_tool_use_id", .null, "session_id", .string("default"))
    ])
  }

  mutating func receive(_ message: JSONValue) -> Step {
    // Sub-agents' messages carry their parent tool call. Only the main agent's are shown.
    let main = message["parent_tool_use_id"] == .null
    switch message["type"].string {
    case "system" where message["subtype"].string == "init":
      return Step(events: message["session_id"].string.map { [.session($0)] } ?? [])
    case "stream_event" where main:
      let delta = message["event"]["delta"]
      guard message["event"]["type"].string == "content_block_delta",
        delta["type"].string == "text_delta", let text = delta["text"].string
      else { return Step() }
      return Step(events: [.text(text, message: message["api_message_id"].string ?? "")])
    case "assistant" where main:
      // A signed-out CLI answers with an error message instead of calling the model.
      if message["error"].string == "authentication_failed" { signedOut = true }
      let tools = message["message"]["content"].array.filter { $0["type"].string == "tool_use" }
      return Step(events: tools.map { .tool(Self.title($0["name"].string ?? "tool", $0["input"])) })
    case "control_request":
      return request(message["request_id"], message["request"])
    case "result":
      let text = message["result"].string ?? ""
      if cancelling { return Step(events: [.finished(cancelled: true)]) }
      if signedOut { return Step(events: [.failed(AgentConfiguration.Agent.claude.signedOut)]) }
      guard message["is_error"].bool || message["subtype"].string != "success" else {
        return Step(events: [.finished(cancelled: false)])
      }
      let errors = message["errors"].array.compactMap(\.string)
      let reason = ([text].filter { !$0.isEmpty } + errors).joined(separator: " ")
      return Step(events: [
        .failed(
          reason.isEmpty
            ? "Claude Code failed (\(message["subtype"].string ?? "no result"))" : reason)
      ])
    default:
      return Step()
    }
  }

  private mutating func request(_ id: JSONValue, _ request: JSONValue) -> Step {
    guard request["subtype"].string == "can_use_tool" else {
      // Wicket registers no hooks or SDK servers, so nothing else should come.
      return Step(send: [Self.response(id, subtype: "error", "error", .string("Wicket does not handle this"))]
      )
    }
    let tool = request["tool_name"].string ?? "tool"
    let input = request["input"]
    // A question needs a form Wicket doesn't have. The agent can ask in its reply instead.
    if tool == "AskUserQuestion" { return Step(send: [Self.answer(id, allow: false)]) }
    pending[id] = input
    let known = Self.files[tool]
    let paths = (known?.keys ?? []).compactMap { input[$0].string }
    return Step(events: [
      .permission(
        AgentPermission(
          id: id, title: Self.title(tool, input),
          kind: tool == "Bash" ? .execute : known?.kind ?? .other, paths: paths,
          command: tool == "Bash" ? input["command"].string : nil,
          raw: .object("tool_name", .string(tool), "input", input)))
    ])
  }

  mutating func decide(_ id: JSONValue, allow: Bool) -> Step {
    // An allow sends the tool's input back unchanged and grants nothing beyond this call.
    guard let input = pending.removeValue(forKey: id) else { return Step() }
    return Step(send: [Self.answer(id, allow: allow, input: input)])
  }

  mutating func cancel() -> Step {
    cancelling = true
    return Step(send: [
      .object(
        "type", .string("control_request"), "request_id", .string("cancel"),
        "request", .object("subtype", .string("interrupt")))
    ])
  }

  /// "Write allowed.txt" or "Bash ls -la": the tool and the first thing its input names.
  static func title(_ tool: String, _ input: JSONValue) -> String {
    let keys = ["file_path", "notebook_path", "path", "command", "pattern", "url", "query", "description"]
    guard let subject = keys.lazy.compactMap({ input[$0].string }).first else { return tool }
    let line = subject.split(whereSeparator: \.isNewline).first.map(String.init) ?? subject
    let short = line.hasPrefix("/") ? (line as NSString).lastPathComponent : line
    return tool + " " + (short.count > 80 ? short.prefix(79) + "…" : short)
  }

  private static func answer(_ id: JSONValue, allow: Bool, input: JSONValue = .null) -> JSONValue {
    response(
      id, subtype: "success", "response",
      allow
        ? .object("behavior", .string("allow"), "updatedInput", input)
        : .object("behavior", .string("deny"), "message", .string("The user declined this in Wicket.")))
  }

  private static func response(_ id: JSONValue, subtype: String, _ key: String, _ body: JSONValue)
    -> JSONValue
  {
    .object(
      "type", .string("control_response"), "response",
      .object("subtype", .string(subtype), "request_id", id, key, body))
  }
}
