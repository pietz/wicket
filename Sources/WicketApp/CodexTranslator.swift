import Foundation

/// Codex through `codex app-server`: JSON-RPC over stdio without the `jsonrpc` field (verified with
/// 0.167). The handshake is initialize, `model/list` and `thread/start` (or `thread/resume`); each
/// turn is `turn/start`, which carries model, effort, speed and the permission policy, so settings
/// never restart the process. Notifications stream the answer and tools until `turn/completed`.
/// Some modes (Auto's `auto_review` reviewer, 0.167) never send it, only `thread/status/changed` to
/// `idle`, which otherwise comes right before it: the turn ends at whichever arrives first.
/// Command and file-change approvals arrive as server requests. The user's own Codex configuration
/// (features, MCP servers) applies.
struct CodexTranslator: Translator {
  static let name = "Codex"
  private let folder: URL
  private let resume: String?
  private let settings: AgentConfiguration
  private var models: [AgentModel]?
  private var thread: String?
  /// A prompt waiting for the thread, and for the model list when the default model is needed.
  private var queued: (text: String, settings: AgentConfiguration)?
  private var turn: String?
  private var turnRequest = 0
  private var nextID = 4
  private var cancelling = false
  private var streamed: Set<String> = []
  /// File changes by item ID: a file-change approval names only its item.
  private var changes: [String: JSONValue] = [:]
  private var turnError: String?
  /// A question was asked and its turn has not ended yet: exactly one ending is reported for it.
  private var awaitingEnd = false
  private var interrupting = false

  init(folder: URL, resume: String?, settings: AgentConfiguration) {
    self.folder = folder
    self.resume = resume
    self.settings = settings
  }

  static func arguments(for settings: AgentConfiguration, resume: String?) -> [String] { ["app-server"] }

  /// The permission labels as Codex's approval policy, sandbox mode and reviewer. Auto lets a
  /// reviewer subagent decide what needs the user.
  private static let policies:
    [String: (approval: String, sandbox: String, policy: String, reviewer: String)] = [
      "read-only": ("on-request", "read-only", "readOnly", "user"),
      "workspace-write": ("on-request", "workspace-write", "workspaceWrite", "user"),
      "agent": ("on-request", "workspace-write", "workspaceWrite", "auto_review"),
      "agent-full-access": ("never", "danger-full-access", "dangerFullAccess", "user"),
    ]

  private static func models(_ result: JSONValue) -> [AgentModel] {
    result["data"].array.compactMap { model in
      guard let id = model["id"].string, !model["hidden"].bool else { return nil }
      return AgentModel(
        id: id, name: model["displayName"].string,
        efforts: model["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string },
        fast: model["serviceTiers"].array.contains { $0["id"].string == "priority" })
    }
  }

  private static func request(_ id: Int, _ method: String, _ params: [String: JSONValue]) -> JSONValue {
    .object("id", .number(Double(id)), "method", .string(method), "params", .object(params))
  }
  private static let handshake: [JSONValue] = [
    request(1, "initialize", ["clientInfo": .object("name", .string("wicket"), "version", .string("1"))]),
    .object("method", .string("initialized")),
    request(2, "model/list", ["limit": .number(100)]),
  ]

  static let listing = Listing(
    arguments: ["app-server"], send: handshake,
    models: { $0["id"] == .number(2) ? models($0["result"]) : nil })

  mutating func start() -> Step {
    var params: [String: JSONValue] = ["cwd": .string(folder.path)]
    if let policy = Self.policies[settings.permissionMode] {
      params["approvalPolicy"] = .string(policy.approval)
      params["approvalsReviewer"] = .string(policy.reviewer)
      params["sandbox"] = .string(policy.sandbox)
    }
    if let resume {
      params["threadId"] = .string(resume)
      params["excludeTurns"] = .bool(true)
    }
    return Step(
      send: Self.handshake + [Self.request(3, resume == nil ? "thread/start" : "thread/resume", params)])
  }

  mutating func prompt(_ text: String, settings: AgentConfiguration) -> Step {
    cancelling = false
    interrupting = false
    awaitingEnd = true
    turnError = nil
    queued = (text, settings)
    return flush()
  }

  /// Starts the queued turn once the thread exists, and the model list if the model is the default.
  private mutating func flush() -> Step {
    guard let thread, let queued, queued.settings.model != nil || models != nil else { return Step() }
    self.queued = nil
    let settings = queued.settings
    guard let policy = Self.policies[settings.permissionMode] else {
      return Step(events: [
        .failed(
          "Unsupported permission mode '\(settings.permissionMode)'. Open Agent settings to see available choices."
        )
      ])
    }
    turnRequest = nextID
    nextID += 1
    return Step(send: [
      Self.request(
        turnRequest, "turn/start",
        [
          "threadId": .string(thread),
          "input": .array([.object("type", .string("text"), "text", .string(queued.text))]),
          "model": .string(settings.model ?? AgentOptions.defaultModel(models ?? [], agent: .codex)),
          "effort": .string(settings.effort ?? "low"),
          // "default" is standard speed even for a model whose catalog default is the fast tier.
          "serviceTierForTurn": .string(settings.speed == "on" ? "priority" : "default"),
          "approvalPolicy": .string(policy.approval), "approvalsReviewer": .string(policy.reviewer),
          "sandboxPolicy": .object("type", .string(policy.policy)),
        ])
    ])
  }

  mutating func receive(_ message: JSONValue) -> Step {
    let id = message["id"]
    let params = message["params"]
    if let method = message["method"].string {
      return id == .null ? notification(method, params) : serverRequest(id, method, params)
    }
    let failure = message["error"]["message"].string
    if id == .number(2) {
      models = Self.models(message["result"])
      return flush()
    } else if id == .number(3) {
      guard let id = message["result"]["thread"]["id"].string else {
        return Step(events: [.failed(failure ?? "Codex started no thread")])
      }
      thread = id
      var step = flush()
      step.events.insert(.session(id), at: 0)
      return step
    } else if id == .number(Double(turnRequest)), turnRequest != 0 {
      if let failure { return Step(events: [.failed(failure)]) }
      turn = message["result"]["turn"]["id"].string
      return cancelling ? interrupt() : Step()
    }
    return Step()
  }

  private mutating func notification(_ method: String, _ params: JSONValue) -> Step {
    switch method {
    case "turn/started":
      turn = params["turn"]["id"].string
      return cancelling ? interrupt() : Step()
    case "item/started":
      return started(params["item"])
    case "item/agentMessage/delta":
      guard let item = params["itemId"].string, let text = params["delta"].string else { return Step() }
      streamed.insert(item)
      return Step(events: [.text(text, message: item)])
    case "item/completed":
      let item = params["item"]
      guard item["type"].string == "agentMessage", let id = item["id"].string,
        let text = item["text"].string, !streamed.contains(id)
      else { return Step() }
      return Step(events: [.text(text, message: id)])
    case "error":
      // Retries ("Reconnecting... 2/5") end in another error or the answer.
      if params["willRetry"] != .bool(true) { turnError = params["error"]["message"].string }
      return Step()
    case "thread/status/changed":
      guard turn != nil, params["status"]["type"].string == "idle" else { return Step() }
      return end(turnError.map { .failed($0) } ?? .finished(cancelled: interrupting))
    case "turn/completed":
      let done = params["turn"]
      switch done["status"].string {
      case "completed": return end(.finished(cancelled: false))
      case "interrupted": return end(.finished(cancelled: true))
      default:
        return end(
          .failed(done["error"]["message"].string ?? turnError ?? "Codex failed without a message"))
      }
    default:
      return Step()
    }
  }

  /// Reports how the turn ended, once: whichever of idle and `turn/completed` comes second is dropped.
  private mutating func end(_ event: AgentEvent) -> Step {
    turn = nil
    guard awaitingEnd else { return Step() }
    awaitingEnd = false
    return Step(events: [event])
  }

  /// The title of a tool that began, and what a file-change approval will need to name.
  private mutating func started(_ item: JSONValue) -> Step {
    switch item["type"].string {
    case "agentMessage", "userMessage", "reasoning", nil:
      return Step()
    case "fileChange":
      if let id = item["id"].string { changes[id] = item["changes"] }
      let names = item["changes"].array.compactMap {
        $0["path"].string.map { ($0 as NSString).lastPathComponent }
      }
      return Step(events: [.tool("Edit " + (names.isEmpty ? "files" : names.joined(separator: ", ")))])
    case "commandExecution":
      return Step(events: [
        .tool("Run " + Self.shortened(Self.unwrapped(item["command"].string ?? "a command")))
      ])
    default:
      return Step(events: [.tool("Use " + (item["tool"].string ?? item["type"].string ?? "a tool"))])
    }
  }

  private mutating func serverRequest(_ id: JSONValue, _ method: String, _ params: JSONValue) -> Step {
    let permission: AgentPermission
    switch method {
    case "item/commandExecution/requestApproval":
      if let host = params["networkApprovalContext"]["host"].string {
        permission = AgentPermission(id: id, title: "Reach " + host, kind: .other, raw: params)
      } else {
        permission = AgentPermission(
          id: id, title: params["reason"].string ?? "Run a command", kind: .execute,
          command: params["command"].string.map(Self.unwrapped), raw: params)
      }
    case "item/fileChange/requestApproval":
      let files = params["itemId"].string.flatMap { changes[$0] } ?? .null
      permission = AgentPermission(
        id: id, title: params["reason"].string ?? "Edit files",
        kind: files.array.contains { $0["kind"]["type"].string == "delete" } ? .delete : .edit,
        paths: files.array.compactMap { $0["path"].string }, raw: files == .null ? params : files)
    default:
      // Anything else is refused, which Codex treats as declined.
      return Step(send: [
        .object(
          "id", id, "error",
          .object("code", .number(-32601), "message", .string("Wicket does not handle this request")))
      ])
    }
    return Step(events: [.permission(permission)])
  }

  mutating func decide(_ id: JSONValue, allow: Bool) -> Step {
    Step(send: [.object("id", id, "result", .object("decision", .string(allow ? "accept" : "decline")))])
  }

  mutating func cancel() -> Step {
    cancelling = true
    // Not started yet: nothing to interrupt.
    if queued != nil {
      queued = nil
      cancelling = false
      awaitingEnd = false
      return Step(events: [.finished(cancelled: true)])
    }
    return interrupt()
  }

  /// Interrupts the turn, or waits for its ID if `turn/start` hasn't answered yet.
  private mutating func interrupt() -> Step {
    guard let thread, let turn else { return Step() }
    cancelling = false
    interrupting = true
    nextID += 1
    return Step(send: [
      Self.request(nextID - 1, "turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
    ])
  }

  /// A command as it will run, without the `zsh -lc '…'` wrapper Codex adds.
  private static func unwrapped(_ command: String) -> String {
    command.wholeMatch(of: #/\/bin\/(?:z|ba)?sh -lc '([^']*)'/#).map { String($0.output.1) } ?? command
  }
  private static func shortened(_ command: String) -> String {
    let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
    return line.count > 80 ? line.prefix(79) + "…" : line
  }
}
