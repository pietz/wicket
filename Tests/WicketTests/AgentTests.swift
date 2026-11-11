import Foundation
import Synchronization
import Testing

@testable import WicketApp

func fixtureURL(_ name: String) -> URL {
  Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
}
/// The CLI's side of a conversation recorded from the real CLI, trimmed.
func recorded(_ name: String) throws -> [JSONValue] {
  try String(contentsOf: fixtureURL(name + ".jsonl"), encoding: .utf8).split(separator: "\n").compactMap {
    let step = try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    return step["out"] == .null ? nil : step["out"]
  }
}
func scratch() throws -> URL {
  let folder = FileManager.default.temporaryDirectory.appending(
    path: "wicket-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}
/// Feeds messages to a translator and gathers everything it answers with.
func feed<T: Translator>(_ translator: inout T, _ messages: some Sequence<JSONValue>) -> Step {
  var all = Step()
  for message in messages {
    let step = translator.receive(message)
    all.events += step.events
    all.send += step.send
  }
  return all
}

// MARK: - Framing

@Test(arguments: ["claude-allow", "claude-cancel", "codex-allow", "codex-patch"])
func recordedTrafficSurvivesArbitraryFraming(_ name: String) throws {
  let messages = try recorded(name)
  let data = try messages.reduce(into: Data()) {
    $0.append(try JSONEncoder().encode($1))
    $0.append(10)
  }
  var framer = LineFramer()
  var result: [JSONValue] = []
  for start in stride(from: 0, to: data.count, by: 7) {
    result += try framer.append(data.subdata(in: start..<min(start + 7, data.count)))
  }
  #expect(result == messages)
  #expect(throws: (any Error).self) { _ = try framer.append(Data(repeating: 65, count: 4_194_305)) }
}

@Test func linesThatAreNotJSONAreSkipped() throws {
  var framer = LineFramer()
  let messages = try framer.append(Data("warning: not json\n{\"a\":1}\n\n".utf8))
  #expect(messages == [.object("a", .number(1))])
}

// MARK: - Claude

@Test func claudeStreamsTextWithMessageBoundariesAndTools() throws {
  var claude = ClaudeTranslator()
  let sent = claude.prompt("What?", settings: .init()).send
  #expect(sent.count == 1 && sent[0]["type"].string == "user")
  #expect(sent[0]["message"]["content"].string == "What?" && sent[0]["session_id"].string == "default")
  let step = feed(&claude, try recorded("claude-allow"))
  let texts = step.events.compactMap { event -> (String, String)? in
    if case .text(let text, let id) = event { return (text, id) } else { return nil }
  }
  #expect(texts.map(\.0) == ["I'll create the file now", ".", "Done"])
  #expect(texts[0].1 == texts[1].1 && texts[1].1 != texts[2].1)
  #expect(step.events.first == .session("fb58656c-9e7c-4247-aa3c-c6463fba5c5b"))
  #expect(step.events.contains(.tool("Write allowed.txt")))
  #expect(step.events.last == .finished(cancelled: false))
}

@Test(arguments: [true, false])
func claudePermissionBecomesACardAndTheReplyEchoesTheInput(_ allow: Bool) throws {
  var claude = ClaudeTranslator()
  let step = feed(&claude, try recorded(allow ? "claude-allow" : "claude-deny"))
  let permission = try #require(
    step.events.compactMap { event -> AgentPermission? in
      if case .permission(let permission) = event { return permission } else { return nil }
    }.first)
  #expect(permission.kind == .edit && permission.title == "Write " + (allow ? "allowed.txt" : "denied.txt"))
  #expect(permission.paths == ["/tmp/wicket-recorded/claude/" + (allow ? "allowed.txt" : "denied.txt")])
  #expect(permission.raw["input"]["file_path"].string == permission.paths.first)
  let reply = try #require(claude.decide(permission.id, allow: allow).send.first)
  #expect(reply["type"].string == "control_response" && reply["response"]["request_id"] == permission.id)
  let decision = reply["response"]["response"]
  #expect(decision["behavior"].string == (allow ? "allow" : "deny"))
  #expect(allow ? decision["updatedInput"] == permission.raw["input"] : decision["message"].string != nil)
  // Answered once: a second reply has nothing to answer.
  #expect(claude.decide(permission.id, allow: allow).send.isEmpty)
}

@Test func claudeCancelInterruptsAndTheNextTurnEndsNormally() throws {
  var claude = ClaudeTranslator()
  let messages = try recorded("claude-cancel")
  _ = claude.prompt("Count", settings: .init())
  let result = try #require(messages.firstIndex { $0["type"].string == "result" })
  var step = feed(&claude, messages[...result].dropLast())
  #expect(
    step.events.contains { if case .text = $0 { true } else { false } }
      && !step.events.contains { if case .failed = $0 { true } else { false } })
  let interrupt = try #require(claude.cancel().send.first)
  #expect(interrupt["request"]["subtype"].string == "interrupt")
  step = feed(&claude, [messages[result]])
  #expect(step.events == [.finished(cancelled: true)])
  _ = claude.prompt("Again", settings: .init())
  step = feed(&claude, messages[(result + 1)...])
  #expect(step.events.last == .finished(cancelled: false))
}

@Test func claudeErrorsReadAsTheCLIPutThem() throws {
  var claude = ClaudeTranslator()
  let step = feed(&claude, try recorded("claude-error"))
  #expect(
    step.events.last
      == .failed(
        "There's an issue with the selected model (imaginary-model). It may not exist or you may not have access to it."
      ))
  #expect(step.events.filter { if case .failed = $0 { true } else { false } }.count == 1)
}

@Test func claudeIgnoresSubAgentsAnswersQuestionsItCannotAskAndRefusesOtherRequests() {
  var claude = ClaudeTranslator()
  let sub = JSONValue.object(
    "type", .string("stream_event"), "parent_tool_use_id", .string("toolu_1"),
    "event",
    .object(
      "type", .string("content_block_delta"), "delta",
      .object("type", .string("text_delta"), "text", .string("hidden"))))
  #expect(claude.receive(sub).events.isEmpty)
  func request(_ subtype: String, tool: String = "") -> JSONValue {
    .object(
      "type", .string("control_request"), "request_id", .string("r"),
      "request", .object("subtype", .string(subtype), "tool_name", .string(tool), "input", .object([:])))
  }
  let question = claude.receive(request("can_use_tool", tool: "AskUserQuestion"))
  #expect(
    question.events.isEmpty && question.send.first?["response"]["response"]["behavior"].string == "deny")
  let hook = claude.receive(request("hook_callback"))
  #expect(hook.events.isEmpty && hook.send.first?["response"]["subtype"].string == "error")
}

@Test func claudeSettingsAreLaunchFlagsAndAChangeNeedsANewProcess() {
  var settings = AgentConfiguration()
  let defaults = ClaudeTranslator.arguments(for: settings, resume: nil)
  #expect(Array(defaults.suffix(6)) == ["--permission-mode", "auto", "--model", "sonnet", "--effort", "low"])
  #expect(
    defaults.contains("stream-json") && defaults.contains("--include-partial-messages")
      && !defaults.contains("--resume"))
  settings.model = "opus"
  settings.effort = "xhigh"
  settings.mode = "acceptEdits"
  settings.speed = "on"
  let explicit = ClaudeTranslator.arguments(for: settings, resume: "session-1")
  #expect(
    Array(explicit.suffix(10)) == [
      "--permission-mode", "acceptEdits", "--model", "opus", "--effort", "xhigh", "--settings",
      #"{"fastMode":true}"#, "--resume", "session-1",
    ])
  #expect(
    ClaudeTranslator.arguments(for: .init(), resume: "x")
      != ClaudeTranslator.arguments(for: settings, resume: "x"))
  #expect(
    CodexTranslator.arguments(for: .init(), resume: nil)
      == CodexTranslator.arguments(for: settings, resume: "x"))
}

@Test func claudeToolTitlesNameTheFirstThingTheInputNames() {
  func title(_ tool: String, _ input: JSONValue) -> String { ClaudeTranslator.title(tool, input) }
  #expect(title("Write", .object("file_path", .string("/a/b/c.txt"))) == "Write c.txt")
  #expect(title("Bash", .object("command", .string("ls -la\nrm x"))) == "Bash ls -la")
  #expect(title("WebSearch", .object("query", .string("rainbows"))) == "WebSearch rainbows")
  #expect(title("Task", .object([:])) == "Task")
  #expect(title("Bash", .object("command", .string(String(repeating: "x", count: 200)))).count == 5 + 80)
}

// MARK: - Codex

private func codex(_ settings: AgentConfiguration = codexSettings(), resume: String? = nil) -> CodexTranslator
{
  CodexTranslator(
    folder: URL(fileURLWithPath: "/tmp/wicket-recorded/codex"), resume: resume, settings: settings)
}
private func codexSettings() -> AgentConfiguration {
  var settings = AgentConfiguration()
  settings.agent = .codex
  return settings
}
private func method(_ line: JSONValue) -> String { line["method"].string ?? "" }

@Test func codexHandshakeStartsOrResumesAThreadAndRepliesAfterTheTurnStarts() throws {
  var fresh = codex()
  let start = fresh.start().send
  #expect(start.map(method) == ["initialize", "initialized", "model/list", "thread/start"])
  #expect(start[3]["params"]["cwd"].string == "/tmp/wicket-recorded/codex")
  var resumed = codex(resume: "thread-1")
  let resume = resumed.start().send[3]
  #expect(method(resume) == "thread/resume" && resume["params"]["threadId"].string == "thread-1")
  #expect(resume["params"]["excludeTurns"].bool)
  // The prompt waits for the thread, then goes out as turn/start.
  #expect(fresh.prompt("Hi", settings: codexSettings()).send.isEmpty)
  let step = fresh.receive(.object("id", .number(2), "result", .object([:])))
  #expect(step.send.isEmpty)
  let turn = fresh.receive(
    .object("id", .number(3), "result", .object("thread", .object("id", .string("t1")))))
  #expect(turn.events == [.session("t1")] && method(turn.send[0]) == "turn/start")
  #expect(turn.send[0]["params"]["input"].array.first?["text"].string == "Hi")
}

@Test(arguments: [
  ("read-only", "on-request", "readOnly", "user"),
  ("workspace-write", "on-request", "workspaceWrite", "user"),
  ("agent", "on-request", "workspaceWrite", "auto_review"),
  ("agent-full-access", "never", "dangerFullAccess", "user"),
])
func codexPermissionLabelsMapToApprovalPolicySandboxAndReviewer(
  _ mode: String, _ approval: String, _ sandbox: String, _ reviewer: String
) throws {
  var settings = codexSettings()
  settings.mode = mode
  settings.model = "gpt-6.1-sol"
  settings.effort = "xhigh"
  settings.speed = "on"
  var translator = codex(settings)
  _ = translator.start()
  _ = translator.prompt("Hi", settings: settings)
  let params = try #require(
    translator.receive(.object("id", .number(3), "result", .object("thread", .object("id", .string("t")))))
      .send.first)["params"]
  #expect(params["approvalPolicy"].string == approval && params["approvalsReviewer"].string == reviewer)
  #expect(params["sandboxPolicy"]["type"].string == sandbox)
  #expect(params["model"].string == "gpt-6.1-sol" && params["effort"].string == "xhigh")
  #expect(params["serviceTierForTurn"].string == "priority")
}

@Test func codexDefaultsAreTheLatestTerraLowEffortAutoAndRegularSpeed() throws {
  var translator = codex()
  _ = translator.start()
  _ = translator.prompt("Hi", settings: codexSettings())
  // The default model needs the list, so the turn waits for it.
  #expect(
    translator.receive(.object("id", .number(3), "result", .object("thread", .object("id", .string("t")))))
      .send.isEmpty)
  let params = try #require(
    translator.receive(.object("id", .number(2), "result", try recorded("codex-models")[0]["result"])).send
      .first)["params"]
  #expect(params["model"].string == "gpt-6.1-terra" && params["effort"].string == "low")
  // "default" is standard speed even for a model whose catalog default is the fast tier.
  #expect(params["serviceTierForTurn"].string == "default")
  #expect(
    params["approvalPolicy"].string == "on-request" && params["approvalsReviewer"].string == "auto_review")
  #expect(params["sandboxPolicy"]["type"].string == "workspaceWrite")
}

@Test func codexStreamsMessagesAndAsksBeforeACommand() throws {
  var translator = codex()
  _ = translator.start()
  _ = translator.prompt("Create it", settings: codexSettings())
  let step = feed(&translator, try recorded("codex-allow"))
  #expect(method(step.send.first { method($0) == "turn/start" } ?? .null) == "turn/start")
  var messages: [String: String] = [:]
  var order: [String] = []
  for case .text(let text, let id) in step.events {
    if messages[id] == nil { order.append(id) }
    messages[id, default: ""] += text
  }
  #expect(order.map { messages[$0] } == ["I’ll create the file.", "Done."])
  let permission = try #require(
    step.events.compactMap { event -> AgentPermission? in
      if case .permission(let permission) = event { return permission } else { return nil }
    }.first)
  #expect(permission.kind == .execute && permission.id == .number(0) && permission.paths.isEmpty)
  #expect(permission.command == "printf ALLOWED > /tmp/wicket-recorded/codex/allowed.txt")
  #expect(permission.title == "May I create the requested file with its exact contents?")
  #expect(
    step.events.contains { if case .tool(let title) = $0 { title.hasPrefix("Run printf") } else { false } })
  #expect(step.events.first == .session("01a1c7d5-7818-74e2-aa16-54bbc9b6e960"))
  #expect(step.events.last == .finished(cancelled: false))
  let allow = try #require(translator.decide(permission.id, allow: true).send.first)
  #expect(allow["id"] == .number(0) && allow["result"]["decision"].string == "accept")
  #expect(
    try #require(translator.decide(.number(0), allow: false).send.first)["result"]["decision"].string
      == "decline")
}

@Test func codexDenyDeclinesAndTheTurnContinues() throws {
  var translator = codex()
  _ = translator.start()
  _ = translator.prompt("Create it", settings: codexSettings())
  let step = feed(&translator, try recorded("codex-deny"))
  #expect(step.events.contains { if case .permission = $0 { true } else { false } })
  #expect(step.events.last == .finished(cancelled: false))
}

@Test func codexFileChangesNameTheirFilesAndDeletionsAreMarked() throws {
  var translator = codex()
  _ = translator.start()
  _ = translator.prompt("Patch", settings: codexSettings())
  let step = feed(&translator, try recorded("codex-patch"))
  let permission = try #require(
    step.events.compactMap { event -> AgentPermission? in
      if case .permission(let permission) = event { return permission } else { return nil }
    }.first)
  #expect(permission.kind == .edit && permission.paths == ["/tmp/wicket-recorded/codex/patched.txt"])
  #expect(step.events.contains(.tool("Edit patched.txt")))
  func approval(kind: String) -> AgentPermission? {
    var other = codex()
    _ = feed(
      &other,
      [
        .object(
          "method", .string("item/started"), "params",
          .object(
            "item",
            .object(
              "type", .string("fileChange"), "id", .string("i"),
              "changes",
              .array([.object("path", .string("/tmp/old.txt"), "kind", .object("type", .string(kind)))]))))
      ])
    let asked = other.receive(
      .object(
        "id", .number(7), "method", .string("item/fileChange/requestApproval"), "params",
        .object("itemId", .string("i"))))
    if case .permission(let permission)? = asked.events.first { return permission }
    return nil
  }
  #expect(approval(kind: "delete")?.kind == .delete && approval(kind: "update")?.kind == .edit)
}

@Test func codexCancelInterruptsTheTurnAndAnUnstartedPromptEndsAtOnce() throws {
  var translator = codex()
  _ = translator.start()
  #expect(translator.prompt("Count", settings: codexSettings()).send.isEmpty)
  // Cancelled before the thread existed: nothing was sent, so nothing to interrupt.
  #expect(translator.cancel().events == [.finished(cancelled: true)])
  _ = translator.prompt("Count", settings: codexSettings())
  let messages = try recorded("codex-cancel")
  let interrupted = try #require(
    messages.firstIndex { $0["params"]["turn"]["status"].string == "interrupted" })
  let step = feed(&translator, messages[..<interrupted])
  #expect(step.events.contains { if case .text = $0 { true } else { false } })
  let interrupt = try #require(translator.cancel().send.first)
  #expect(
    method(interrupt) == "turn/interrupt" && interrupt["params"]["threadId"].string != nil
      && interrupt["params"]["turnId"].string != nil)
  #expect(feed(&translator, [messages[interrupted]]).events == [.finished(cancelled: true)])
  // Cancel before turn/start answered: the interrupt waits for the turn's ID.
  var early = codex()
  _ = early.start()
  _ = early.prompt("Count", settings: codexSettings())
  _ = early.receive(.object("id", .number(2), "result", try recorded("codex-models")[0]["result"]))
  _ = early.receive(.object("id", .number(3), "result", .object("thread", .object("id", .string("t")))))
  #expect(early.cancel().send.isEmpty)
  let late = early.receive(
    .object("id", .number(4), "result", .object("turn", .object("id", .string("turn-1")))))
  #expect(method(late.send[0]) == "turn/interrupt" && late.send[0]["params"]["turnId"].string == "turn-1")
}

@Test func codexResumesAThreadWithTheSettingsOfNow() throws {
  var settings = codexSettings()
  settings.model = "gpt-6-luna"
  settings.effort = "medium"
  var translator = codex(settings, resume: "01a1c7cc-513a-75a3-b649-6c9853275edb")
  #expect(method(translator.start().send[3]) == "thread/resume")
  _ = translator.prompt("Codeword?", settings: settings)
  let step = feed(&translator, try recorded("codex-resume"))
  let turn = try #require(step.send.first { method($0) == "turn/start" })
  #expect(turn["params"]["model"].string == "gpt-6-luna" && turn["params"]["effort"].string == "medium")
  #expect(turn["params"]["threadId"].string == "01a1c7cc-513a-75a3-b649-6c9853275edb")
  #expect(step.events.first == .session("01a1c7cc-513a-75a3-b649-6c9853275edb"))
  #expect(step.events.last == .finished(cancelled: false))
}

@Test func codexFailuresUseTheCLIsMessageAndRetriesAreNotFailures() throws {
  var translator = codex()
  _ = translator.start()
  _ = feed(
    &translator,
    [
      .object(
        "method", .string("error"), "params",
        .object("willRetry", .bool(true), "error", .object("message", .string("Reconnecting... 1/5"))))
    ])
  let completed = JSONValue.object(
    "method", .string("turn/completed"), "params",
    .object("turn", .object("status", .string("failed"), "error", .null)))
  #expect(feed(&translator, [completed]).events == [.failed("Codex failed without a message")])
  _ = feed(
    &translator,
    [
      .object(
        "method", .string("error"), "params",
        .object(
          "willRetry", .bool(false), "error", .object("message", .string("The 'x' model is not supported"))))
    ])
  #expect(feed(&translator, [completed]).events == [.failed("The 'x' model is not supported")])
  let refused = translator.receive(
    .object("id", .number(3), "error", .object("message", .string("no thread"))))
  #expect(refused.events == [.failed("no thread")])
  let other = translator.receive(
    .object("id", .number(9), "method", .string("item/tool/requestUserInput"), "params", .object([:])))
  #expect(other.events.isEmpty && other.send.first?["error"]["code"] == .number(-32601))
}

// MARK: - Models

@Test func bothCLIsListTheirModelsWithoutAModelCall() throws {
  let claude = try #require(ClaudeTranslator.listing.models(try recorded("claude-models")[0]))
  #expect(claude.map(\.id) == ["opus", "fable", "sonnet", "haiku", "claude-haiku-4-5-20251001"])
  #expect(claude.first { $0.id == "sonnet" }?.name == "Sonnet 5.5")
  #expect(claude.first { $0.id == "opus" }?.fast == true && claude.first { $0.id == "sonnet" }?.fast == false)
  #expect(claude.first { $0.id == "haiku" }?.efforts.contains("xhigh") == true)
  #expect(claude.first { $0.id.hasPrefix("claude-haiku-4") }?.efforts == [])
  #expect(ClaudeTranslator.listing.models(.object("type", .string("system"))) == nil)
  let codex = try #require(CodexTranslator.listing.models(try recorded("codex-models")[0]))
  #expect(codex.map(\.id) == ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-luna"])
  #expect(
    codex[1].name == "GPT-6.1 Terra" && codex[1].fast
      && codex[1].efforts == ["low", "medium", "high", "xhigh"])
  #expect(CodexTranslator.listing.send.map(method) == ["initialize", "initialized", "model/list"])
  #expect(ClaudeTranslator.listing.send.first?["request"]["subtype"].string == "initialize")
}

// MARK: - The process

/// A recorded conversation replayed by a real process through the real framing and translator.
@MainActor
private func replay<T: Translator>(
  _ name: String, _ translator: T, ask: String = "Hi", answer allow: Bool = true,
  settings: AgentConfiguration = .init()
) async throws -> [AgentEvent] {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let lines = try JSONLines(
    command: ["/usr/bin/python3", fixtureURL("cli-peer.py").path, fixtureURL(name + ".jsonl").path],
    folder: folder)
  let link = AgentLink(translator, lines: lines)
  var events: [AgentEvent] = []
  link.onEvent = { event in
    events.append(event)
    if case .permission(let permission) = event { link.decide(permission.id, allow: allow) }
  }
  link.prompt(ask, settings: settings)
  let finished = await eventually { events.contains { if case .finished = $0 { true } else { false } } }
  await link.stop()
  try #require(finished, "events: \(events)")
  return events
}

@MainActor @Test(arguments: [true, false])
func claudeConversationRunsThroughARealProcessAndAnswersTheCard(_ allow: Bool) async throws {
  let events = try await replay(allow ? "claude-allow" : "claude-deny", ClaudeTranslator(), answer: allow)
  #expect(events.contains { if case .permission = $0 { true } else { false } })
  #expect(
    events.contains(.finished(cancelled: false))
      && !events.contains { if case .failed = $0 { true } else { false } })
}

@MainActor @Test(arguments: [true, false])
func codexConversationRunsThroughARealProcessAndAnswersTheCard(_ allow: Bool) async throws {
  var settings = codexSettings()
  settings.model = "gpt-6.1-terra"
  let translator = CodexTranslator(
    folder: URL(fileURLWithPath: "/tmp/wicket-recorded/codex"), resume: nil, settings: settings)
  let events = try await replay(
    allow ? "codex-allow" : "codex-deny", translator, answer: allow, settings: settings)
  #expect(events.contains { if case .permission = $0 { true } else { false } })
  #expect(events.contains(.finished(cancelled: false)))
}

@MainActor @Test func theProcessDeliversWritesInOrderBothWaysAndAnEndingProcessIsAFailure() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  // cat echoes every line: ordered, whole and with text that straddles reads.
  let echo = try JSONLines(command: ["/bin/cat"], folder: folder)
  var got: [JSONValue] = []
  echo.onMessage = { got.append($0) }
  let big = String(repeating: "Snowman ☃ ", count: 100_000)
  let sent: [JSONValue] = [.string("first"), .string(big), .object("n", .number(3)), .string("last")]
  for value in sent { echo.send(value) }
  #expect(await eventually { got.count == 4 })
  #expect(got == sent)
  await echo.stop()
  // A process that ends, even cleanly, is a failure with its stderr.
  let ending = try JSONLines(
    command: ["/usr/bin/python3", "-c", "import sys; sys.stderr.write('boom\\n')"], folder: folder)
  var reason: String?
  ending.onClose = { reason = $0 }
  #expect(await eventually { reason != nil })
  #expect(reason?.contains("exited with status 0") == true && reason?.contains("boom") == true)
  await ending.stop()
  // Stopping is not a failure.
  let quiet = try JSONLines(command: ["/bin/cat"], folder: folder)
  var closed = false
  quiet.onClose = { _ in closed = true }
  await quiet.stop()
  try await Task.sleep(for: .milliseconds(50))
  #expect(!closed)
  #expect(throws: (any Error).self) {
    _ = try JSONLines(command: ["/nonexistent/wicket-cli"], folder: folder)
  }
}

@MainActor @Test func aProcessThatExitsIsAFailureEvenWhileADescendantKeepsItsOutputOpen() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let lines = try JSONLines(
    command: ["/bin/sh", "-c", "sleep 30 & echo diagnostic >&2; exit 3"], folder: folder)
  var reason: String?
  lines.onClose = { reason = $0 }
  let deadline = ContinuousClock.now + .seconds(5)
  while reason == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  #expect(
    reason?.contains("exited with status 3") == true && reason?.contains("diagnostic") == true,
    "\(reason ?? "nil")")
  let start = ContinuousClock.now
  await lines.stop()
  #expect(ContinuousClock.now - start < .seconds(3))
}

@Test func readingStopsAtTheLimitInsteadOfQueueingAFlood() async throws {
  let flood = try Launch.start(
    URL(fileURLWithPath: "/usr/bin/yes"), [], in: FileManager.default.temporaryDirectory,
    environment: Launch.environment())
  let tree = flood.tree
  let stopped = Mutex(false)
  let chunks = flood.stdout.chunks(limit: 100_000) {
    stopped.withLock { $0 = true }
    tree.stop(after: .zero, grace: .milliseconds(100))
  }
  // Nobody consumes for a while: an unbounded reader would keep queueing meanwhile.
  try await Task.sleep(for: .milliseconds(300))
  var total = 0
  for await chunk in chunks { total += chunk.count }
  #expect(stopped.withLock { $0 } && total > 100_000 && total <= 100_000 + 1_048_576)
  _ = await tree.stop(after: .zero, grace: .milliseconds(100)).value
  // Lines are bounded one at a time: plenty of short lines are not a flood.
  let lines = try Launch.start(
    URL(fileURLWithPath: "/usr/bin/python3"), ["-c", "for _ in range(500): print('x' * 99)"],
    in: FileManager.default.temporaryDirectory, environment: Launch.environment())
  var counted = 0
  for await chunk in lines.stdout.chunks(
    limit: 1_000, perLine: true, exceeded: { Issue.record("a line limit counted all lines together") })
  { counted += chunk.count }
  #expect(counted >= 50_000)
}

@MainActor @Test func aFrameBeyondFourMebibytesIsAFailure() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let lines = try JSONLines(
    command: [
      "/usr/bin/python3", "-c",
      "import sys; sys.stdout.write('a' * 5000000); sys.stdout.flush(); sys.stdin.read()",
    ], folder: folder)
  var reason: String?
  lines.onClose = { reason = $0 }
  #expect(await eventually { reason != nil })
  #expect(reason?.contains("4 MiB") == true)
  await lines.stop()
}

@Test func loginCheckRecognizesLogoutWithoutPrompting() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  func check(_ cli: String, _ arguments: [String] = []) async throws {
    try await AgentCLI.checkLogin(
      URL(fileURLWithPath: cli), arguments: arguments, signIn: "claude auth login", in: folder)
  }
  try await check("/usr/bin/true")
  try await check("/bin/echo", [#"{"loggedIn":true}"#])
  await #expect(throws: AgentFailure.self) { try await check("/usr/bin/false") }
  await #expect(throws: AgentFailure.self) { try await check("/bin/echo", [#"{"loggedIn":false}"#]) }
  do { try await check("/usr/bin/false") } catch {
    #expect(error.localizedDescription == "Sign in first: claude auth login")
  }
  do {
    try await AgentCLI.checkLogin(
      URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], signIn: "x", in: folder)
    Issue.record("returned")
  } catch { #expect(error.localizedDescription.contains("timed out")) }
}

@Test func theSharedLookupUsesOnlyThePathNeverTheWorkingFolder() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for path in ["work/claude", "bin/tool"] {
    let file = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }
  let environment = ["PATH": root.appending(path: "bin").path]
  #expect(Launch.which("tool", in: environment) == root.appending(path: "bin/tool"))
  #expect(Launch.which("claude", in: environment) == nil)
  let extended = try #require(Launch.environment(environment)["PATH"])
  #expect(
    extended.hasPrefix(root.appending(path: "bin").path + ":") && extended.contains("/opt/homebrew/bin")
      && extended.hasSuffix("/bin"))
  #expect(throws: AgentFailure.self) { _ = try AgentCLI.executable(.claude, in: environment) }
  do { _ = try AgentCLI.executable(.codex, in: environment) } catch {
    #expect(
      error.localizedDescription == "Codex isn't installed. Install it, then run codex login in Terminal.")
  }
}

@Test func agentConfigAllowsPartialEditsAndRejectsUnknownAgents() throws {
  let config = try JSONDecoder().decode(
    Configuration.self, from: Data(#"{"agent":{"model":"sonnet","effort":"low"}}"#.utf8))
  #expect(config.agent.agent == .claude && config.agent.permissionMode == "auto")
  #expect(config.agent.model == "sonnet" && config.agent.effort == "low")
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      Configuration.self, from: Data(#"{"agent":{"name":"imaginary"}}"#.utf8))
  }
  let codex = try JSONDecoder().decode(
    Configuration.self, from: Data(#"{"agent":{"name":"codex"}}"#.utf8))
  #expect(codex.agent.permissionMode == "agent")
}

@Test func stoppingTheProcessTreeStopsChildrenInAnotherSession() async throws {
  let started = try Launch.start(
    URL(fileURLWithPath: "/usr/bin/python3"),
    [
      "-c",
      "import subprocess,time; c=subprocess.Popen(['/bin/sleep','30'],start_new_session=True); print(c.pid,flush=True); time.sleep(30)",
    ],
    in: FileManager.default.temporaryDirectory, environment: Launch.environment())
  _ = await Task.detached { started.stdout.availableData }.value
  #expect(started.tree.members().count >= 2)
  _ = await started.tree.stop(after: .zero, grace: .milliseconds(50)).value
  #expect(started.tree.members().isEmpty)
}

// MARK: - The session

@MainActor
final class FakeAgent: AgentConnection {
  var onEvent: (AgentEvent) -> Void = { _ in }
  var prompts: [(text: String, settings: AgentConfiguration)] = []
  var decisions: [(id: JSONValue, allow: Bool)] = []
  var cancels = 0
  /// A turn was prompted and has not ended.
  var running = false
  var stopped = false
  var ignoresCancel = false
  var stopDelay: Duration = .zero
  var stopFinished = false
  func prompt(_ text: String, settings: AgentConfiguration) {
    prompts.append((text, settings))
    running = true
  }
  func decide(_ id: JSONValue, allow: Bool) { decisions.append((id, allow)) }
  func cancel() {
    cancels += 1
    if !ignoresCancel { end(cancelled: true) }
  }
  func stop() async {
    stopped = true
    running = false
    try? await Task.sleep(for: stopDelay)
    stopFinished = true
  }
  func end(cancelled: Bool = false) {
    running = false
    onEvent(.finished(cancelled: cancelled))
  }
  func text(_ value: String, message: String = "m1") { onEvent(.text(value, message: message)) }
  func tool(_ title: String) { onEvent(.tool(title)) }
  func ask(_ id: Int = 1) { onEvent(.permission(Self.permission(id))) }
  static func permission(_ id: Int, kind: AgentPermission.Kind = .edit) -> AgentPermission {
    AgentPermission(
      id: .number(Double(id)), title: "Write allowed.txt", kind: kind,
      paths: ["/tmp/wicket-recorded/claude/allowed.txt"],
      raw: .object(
        "tool_name", .string("Write"), "input",
        .object("file_path", .string("/tmp/wicket-recorded/claude/allowed.txt"))))
  }
}

@MainActor @Test(arguments: ["claude", "codex"])
func sessionStreamsMergesPermissionsAndEveryQuestionStartsItsOwnProcessThatResumes(_ name: String)
  async throws
{
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let first = FakeAgent()
  let second = FakeAgent()
  let third = FakeAgent()
  let fourth = FakeAgent()
  let session = AgentSession(folder: folder)
  var starts: [(AgentConfiguration, String?)] = []
  session.connect = { settings, _, resume in
    starts.append((settings, resume))
    return [first, second, third, fourth][starts.count - 1]
  }
  var settings = AgentConfiguration()
  settings.agent = name == "claude" ? .claude : .codex
  settings.model = name == "claude" ? "sonnet" : "gpt-6.1-sol"
  session.ask("Remember LANTERN-47", settings: settings)
  #expect(await eventually { first.running })
  #expect(session.active && session.busy && starts[0].1 == nil)
  #expect(
    first.prompts[0].text.hasSuffix("User: Remember LANTERN-47") && first.prompts[0].settings == settings)
  first.onEvent(.session("recorded-session"))
  first.text("Hello ")
  first.text("world")
  #expect(session.answer == "Hello world" && session.sessionID == "recorded-session")
  first.tool("Write allowed.txt")
  #expect(session.status == "Write allowed.txt")
  first.ask(7)
  #expect(session.permissions.count == 1)
  session.decide(false)
  #expect(first.decisions.count == 1 && first.decisions[0].id == .number(7) && !first.decisions[0].allow)
  #expect(session.permissions.isEmpty)
  first.end()
  #expect(await eventually { !session.busy })
  #expect(session.answer == "Hello world" && session.status == "Ready for a follow-up")
  #expect(await eventually { first.stopped })
  session.reopen()
  #expect(session.active)
  // The turn ended its process: a follow-up starts a new one that resumes the session.
  session.ask("What was it?", settings: settings)
  #expect(await eventually { second.running })
  #expect(session.answer.isEmpty && session.permissions.isEmpty)
  #expect(starts.count == 2 && starts[1].1 == "recorded-session" && starts[1].0 == settings)
  second.text("LANTERN-47")
  second.end()
  #expect(await eventually { !session.busy && second.stopped })
  #expect(second.prompts.count == 1)
  // Changed settings simply apply to the next launch, which resumes the same session.
  settings.effort = "high"
  session.ask("Think", settings: settings)
  #expect(await eventually { third.running })
  #expect(starts.count == 3 && starts[2].1 == "recorded-session" && starts[2].0.effort == "high")
  third.text("partial")
  session.cancel()
  #expect(third.cancels == 1)
  #expect(await eventually { !session.busy && third.stopped })
  #expect(session.status == "Cancelled")
  session.ask("Once more", settings: settings)
  #expect(await eventually { fourth.running })
  #expect(starts.count == 4 && starts[3].1 == "recorded-session")
  fourth.end()
  #expect(await eventually { !session.busy })
  session.reopen(now: Date().addingTimeInterval(301))
  #expect(!session.active && session.sessionID == nil)
  await session.shutdown()
}

@MainActor @Test func aCLIErrorBecomesAReadableProblemAndTheNextQuestionStartsFresh() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  let session = AgentSession(folder: folder)
  session.connect = { _, _, _ in fake }
  var settings = AgentConfiguration()
  settings.model = "imaginary-model"
  session.ask("hello", settings: settings)
  #expect(await eventually { fake.running })
  fake.text("Partial")
  fake.onEvent(.failed("There's an issue with the selected model (imaginary-model)."))
  #expect(await eventually { !session.busy })
  #expect(
    session.problem == "There's an issue with the selected model (imaginary-model)."
      && session.answer == "Partial")
  #expect(await eventually { fake.stopped })
  // A connection that cannot start at all says why.
  session.connect = { _, _, _ in throw AgentFailure("Sign in first: claude auth login") }
  session.ask("again", settings: .init())
  #expect(await eventually { !session.busy })
  #expect(session.problem == "Sign in first: claude auth login" && session.status == session.problem)
  await session.shutdown()
}

@MainActor @Test func aSilentCLIAndALongTurnAreBounded() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let silent = FakeAgent()
  let session = AgentSession(folder: folder)
  session.startupLimit = .milliseconds(30)
  session.turnLimit = .milliseconds(250)
  session.connect = { _, _, _ in silent }
  session.ask("Hello", settings: .init())
  #expect(await eventually { !session.busy })
  #expect(session.problem?.contains("took too long") == true)
  #expect(await eventually { silent.stopped })
  // Once it speaks, the longer limit applies.
  let slow = FakeAgent()
  session.connect = { _, _, _ in slow }
  session.ask("Hello", settings: .init())
  #expect(await eventually { slow.running })
  slow.tool("Working")
  try await Task.sleep(for: .milliseconds(80))
  #expect(session.busy && session.problem == nil)
  slow.end()
  #expect(await eventually { !session.busy })
  // A process that ends after its turn is not an error.
  slow.onEvent(.failed("Claude Code exited with status 1."))
  #expect(session.problem == nil && session.status == "Ready for a follow-up")
  #expect(await eventually { slow.stopped })
  // A turn that never ends expires, is declined whatever it still asks, and loses its process.
  let endless = FakeAgent()
  session.connect = { _, _, _ in endless }
  session.ask("Hello", settings: .init())
  #expect(await eventually { endless.running })
  endless.tool("Working")
  endless.ask(9)
  #expect(session.permissions.count == 1)
  #expect(await eventually { !session.busy })
  #expect(session.problem?.contains("took too long") == true && session.permissions.isEmpty)
  #expect(
    endless.decisions.count == 1 && endless.decisions[0].id == .number(9) && !endless.decisions[0].allow)
  #expect(await eventually { endless.stopped })
  await session.shutdown()
}

@MainActor @Test func escapeCancelsTheTurnThenLeavesTheConversation() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder)
  let fake = FakeAgent()
  var starts = 0
  model.agent.connect = { _, _, _ in
    starts += 1
    return fake
  }
  model.input = "One"
  model.ask()
  #expect(await eventually { fake.running })
  fake.text("First")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.input = "Two"
  #expect(model.agent.active)
  model.ask()
  #expect(await eventually { fake.running })
  fake.text("Second")
  #expect(model.agent.answer == "Second" && starts == 2)
  #expect(model.escape())
  #expect(await eventually { !model.agent.busy })
  #expect(model.agent.active)
  #expect(model.escape())
  #expect(!model.agent.active && model.agent.answer.isEmpty)
  #expect(!model.escape())
  await model.finish()
}

@MainActor @Test func stalledCancellationCannotOverwriteItsFinalState() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  let session = AgentSession(folder: folder)
  fake.ignoresCancel = true
  session.cancelGrace = .milliseconds(20)
  session.connect = { _, _, _ in fake }
  session.ask("Hello", settings: AgentConfiguration())
  #expect(await eventually { fake.running })
  session.cancel()
  #expect(await eventually { !session.busy })
  await Task.yield()
  #expect(session.status == "Cancelled" && session.problem == nil && fake.stopped)
  await session.shutdown()
}

@MainActor @Test func cancellingDeclinesLaterPermissionsAndARepeatedCancelChangesNothing() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  fake.ignoresCancel = true
  let session = AgentSession(folder: folder)
  session.cancelGrace = .seconds(30)
  session.connect = { _, _, _ in fake }
  session.ask("Hello", settings: AgentConfiguration())
  #expect(await eventually { fake.running })
  fake.ask(1)
  session.cancel()
  #expect(fake.decisions.count == 1 && !fake.decisions[0].allow && session.permissions.isEmpty)
  // The CLI keeps asking while it winds down: every request is refused, none becomes a card.
  fake.ask(2)
  #expect(session.permissions.isEmpty && fake.decisions.count == 2)
  #expect(fake.decisions[1].id == .number(2) && !fake.decisions[1].allow)
  session.decide(true)
  #expect(fake.decisions.count == 2)
  session.cancel()
  #expect(fake.cancels == 1 && session.status == "Cancelling…")
  fake.end(cancelled: true)
  #expect(await eventually { !session.busy })
  #expect(session.status == "Cancelled")
  await session.shutdown()
}

@MainActor @Test func cancellingWhileConnectingNeverSendsTheQuestion() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  let session = AgentSession(folder: folder)
  session.cancelGrace = .seconds(30)
  var release: CheckedContinuation<Void, Never>?
  var connecting = false
  session.connect = { _, _, _ in
    connecting = true
    await withCheckedContinuation { release = $0 }
    return fake
  }
  session.ask("Hello", settings: AgentConfiguration())
  #expect(await eventually { connecting && release != nil })
  session.cancel()
  release?.resume()
  #expect(await eventually { !session.busy })
  #expect(fake.prompts.isEmpty && fake.stopped && session.status == "Cancelled" && session.problem == nil)
  await session.shutdown()
}

@MainActor @Test func shutdownWaitsForEveryProcessItStartedEvenAfterATurnEnded() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let session = AgentSession(folder: folder)
  let first = FakeAgent()
  first.stopDelay = .milliseconds(150)
  session.connect = { _, _, _ in first }
  session.ask("One", settings: AgentConfiguration())
  #expect(await eventually { first.running })
  first.end()
  #expect(await eventually { !session.busy })
  // Quit right after the turn: the process that the turn released is still stopping.
  await session.shutdown()
  #expect(first.stopFinished)
  // And one that was still starting is stopped once it arrives.
  let second = FakeAgent()
  second.stopDelay = .milliseconds(100)
  var release: CheckedContinuation<Void, Never>?
  session.connect = { _, _, _ in
    await withCheckedContinuation { release = $0 }
    return second
  }
  session.ask("Two", settings: AgentConfiguration())
  #expect(await eventually { release != nil })
  let quitting = Task { await session.shutdown() }
  try await Task.sleep(for: .milliseconds(20))
  release?.resume()
  await quitting.value
  #expect(second.prompts.isEmpty && second.stopFinished)
}

@MainActor @Test(arguments: [true, false])
func separateAgentMessagesAreSeparateParagraphsStreamingOrNot(_ streaming: Bool) async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  let session = AgentSession(folder: folder)
  session.connect = { _, _, _ in fake }
  var settings = AgentConfiguration()
  settings.streamAnswers = streaming
  session.ask("Hello", settings: settings)
  #expect(await eventually { fake.running })
  fake.text("Checking", message: "a")
  fake.text(".", message: "a")
  fake.text("", message: "b")
  fake.text("# Result", message: "b")
  fake.tool("Read file")
  fake.text("Done", message: "c")
  fake.end()
  #expect(await eventually { !session.busy })
  #expect(session.answer == "Checking.\n\n# Result\n\nDone")
  await session.shutdown()
}
