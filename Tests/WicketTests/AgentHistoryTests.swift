import Foundation
import Testing

@testable import WicketApp

private typealias Run = AgentHistory.Run

private func run(
  _ id: String, _ turns: [(String, String)], agent: AgentConfiguration.Agent = .claude,
  session: String? = "session-\(UUID().uuidString)", used: Date = Date(), source: String? = nil
) -> Run {
  Run(
    id: id, agent: agent, session: session, used: used, source: source,
    turns: turns.map { .init(question: $0.0, answer: $0.1) })
}

/// A launcher with Agent History whose agent processes are fakes, handed out in order.
@MainActor private final class Bench {
  let folder: URL
  let runs: AgentHistory
  let model: LauncherModel
  var fakes: [FakeAgent] = []
  var starts: [(agent: AgentConfiguration.Agent, resume: String?)] = []
  init() throws {
    folder = try scratch()
    runs = AgentHistory(url: folder.appending(path: "private/agent-history.json"))
    model = LauncherModel(
      agentHistory: runs, history: UsageHistory(url: folder.appending(path: "usage.json")),
      folder: folder)
    model.store.start(watching: false)
    model.agent.connect = { [unowned self] settings, _, resume in
      starts.append((settings.agent, resume))
      let fake = FakeAgent()
      fakes.append(fake)
      return fake
    }
  }
  /// Opens Agent History from the root and reopens the row with this title.
  func reopen(_ title: String) async throws {
    model.input = "history"
    await model.settled()
    let row = try #require(model.results.first { $0.provider == "history" })
    #expect(row.row.title == AgentHistory.title)
    model.select(row.id)
    #expect(model.activateReturn())
    await model.settled()
    #expect(model.command?.id == "history" && model.commandName == AgentHistory.title)
    let entry = try #require(model.results.first { $0.row.title == title })
    model.select(entry.id)
    #expect(model.activateReturn())
  }
  func finish() async {
    await model.finish()
    try? FileManager.default.removeItem(at: folder)
  }
}

@MainActor @Test func aTurnIsSavedWhenItEndsWithoutItsContextAndAFollowUpUpdatesTheSameRun() async throws {
  let folder = try scratch()
  let url = folder.appending(path: "private/agent-history.json")
  let runs = AgentHistory(url: url)
  let session = AgentSession(folder: folder)
  session.history = runs
  let fake = FakeAgent()
  session.connect = { _, _, _ in fake }
  session.ask("Add the wind", context: "<context>secret view</context>", from: "Weather", settings: .init())
  #expect(await eventually { fake.running })
  #expect(runs.runs.isEmpty)
  fake.onEvent(.session("s-1"))
  fake.tool("Read main.py")
  fake.text("Added it.")
  fake.end()
  #expect(await eventually { !session.busy })
  let saved = try #require(runs.runs.first)
  #expect(saved.session == "s-1" && saved.source == "Weather" && saved.agent == .claude)
  #expect(saved.turns == [.init(question: "Add the wind", answer: "Added it.")])
  try await finishTurn(session, "And gusts?", "Gusts too.")
  #expect(runs.runs.count == 1 && runs.runs[0].id == saved.id && runs.runs[0].turns.count == 2)
  #expect(runs.runs[0].source == "Weather")
  // Ending the conversation starts a new run.
  session.reset()
  try await finishTurn(session, "Something else", "Sure.")
  #expect(runs.runs.map { $0.turns[0].question } == ["Something else", "Add the wind"])
  // Persisted owner-only, read back by a new instance, and the agent's context never written.
  await runs.finish()
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(!text.contains("secret view") && !text.contains("Read main.py"))
  let mode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[
    .posixPermissions]
  #expect(mode as? Int == 0o700)
  let reloaded = AgentHistory(url: url).runs
  #expect(reloaded.map(\.id) == runs.runs.map(\.id) && reloaded.map(\.turns) == runs.runs.map(\.turns))
  await session.shutdown()
}

@MainActor @Test func retentionKeepsTheNewestHundredForThirtyDays() throws {
  let runs = AgentHistory(url: try scratch().appending(path: "agent-history.json"))
  let start = Date(timeIntervalSince1970: 1_000_000)
  let count = AgentHistory.maxEntries + 2
  for index in 0..<count {
    let used = start.addingTimeInterval(Double(index) * 3600)
    runs.save(run("\(index)", [("q\(index)", "a")], used: used), now: used)
  }
  #expect(runs.runs.count == AgentHistory.maxEntries && runs.runs.last?.id == "2")
  let expiry = Double(AgentHistory.maxDays) * 24 * 3600
  let rows = runs.rows(matching: "", now: start.addingTimeInterval(Double(count - 2) * 3600 + expiry + 1800))
  #expect(rows.map(\.title) == ["q\(count - 1)"])
}

@MainActor @Test func rowsFilterAcrossQuestionsAndAnswersAndDeleteOrClear() throws {
  let runs = AgentHistory(url: try scratch().appending(path: "agent-history.json"))
  runs.save(run("a", [("Weather in  Berlin\ntomorrow", "Sunny"), ("And Hamburg?", "Rain, über 20 mm")]))
  runs.save(run("b", [("Mutex or actor?", "An actor")], agent: .codex))
  #expect(runs.rows(matching: "").map(\.title) == ["Mutex or actor?", "Weather in Berlin tomorrow"])
  #expect(runs.rows(matching: "").first?.subtitle?.hasSuffix(" · ChatGPT") == true)
  // Every word somewhere in the run, case and diacritics ignored, in any question or answer.
  #expect(runs.rows(matching: "UBER berlin").map(\.id) == ["a"])
  #expect(runs.rows(matching: "actor").map(\.id) == ["b"])
  #expect(runs.rows(matching: "actor rain").isEmpty)
  let row = try #require(runs.rows(matching: "hamburg").first)
  #expect(
    row.actions == [
      .run(Address(arguments: ["open": "a"]), title: "Reopen"),
      .run(Address(arguments: ["delete": "a"]), title: "Delete"),
    ])
  // Delete is the row's own run action, answered with the updated list; clear empties it.
  let view = runs.view(for: ProviderRequest(input: "", arguments: ["delete": "a"], submitted: true))
  #expect(view.items.map(\.id) == ["b"] && runs.runs.map(\.id) == ["b"])
  runs.clear()
  #expect(runs.runs.isEmpty && runs.view(for: ProviderRequest(input: "")).items.isEmpty)
}

@MainActor @Test func returnReopensTheRunAsItWasAndAFollowUpResumesItsSessionAndAgent() async throws {
  let bench = try Bench()
  let model = bench.model
  bench.runs.save(
    run(
      "r1", [("Weather in Berlin?", "Sunny"), ("And Hamburg?", "Rain")], agent: .codex, session: "thread-1",
      source: "Weather"))
  try await bench.reopen("Weather in Berlin?")
  #expect(model.agent.active && model.agent.continuing && !model.agent.busy)
  #expect(model.agent.question == "And Hamburg?" && model.agent.answer == "Rain")
  #expect(model.agent.previous.map(\.question) == ["Weather in Berlin?"])
  #expect(model.agent.sessionID == "thread-1" && model.agent.agentName == "ChatGPT")
  // The source belongs to the first question, which is not the one under the header now.
  #expect(model.agent.source == nil && model.input == "" && bench.starts.isEmpty)
  // Claude is configured, but the run keeps its agent and resumes its thread.
  model.send("And Munich?")
  #expect(await eventually { bench.fakes.first?.running == true })
  #expect(bench.starts.count == 1 && bench.starts[0].agent == .codex && bench.starts[0].resume == "thread-1")
  let fake = bench.fakes[0]
  fake.onEvent(.session("thread-1"))
  fake.text("Clouds")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  #expect(model.agent.notice == nil && model.agent.previous.count == 2)
  let saved = try #require(bench.runs.runs.first)
  #expect(saved.id == "r1" && saved.session == "thread-1" && saved.source == "Weather")
  #expect(saved.turns.map(\.answer) == ["Sunny", "Rain", "Clouds"])
  // Escape ends the conversation and goes back to the list, the run on top.
  #expect(model.escape())
  await model.settled()
  #expect(!model.agent.active && model.command?.id == "history")
  #expect(model.results.first?.row.title == "Weather in Berlin?")
  await bench.finish()
}

@MainActor @Test(arguments: [true, false])
func aSessionTheCLINoLongerHasStartsAfreshWithOneQuietLine(_ claude: Bool) async throws {
  let bench = try Bench()
  let model = bench.model
  bench.runs.save(
    run("r1", [("What is a mutex?", "A lock")], agent: claude ? .claude : .codex, session: "gone"))
  try await bench.reopen("What is a mutex?")
  model.send("And a semaphore?")
  #expect(await eventually { bench.fakes.first?.running == true })
  // The CLI's own answer to an unknown session, before it reported any session.
  bench.fakes[0].onEvent(
    .failed(claude ? "No conversation found with session ID: gone" : "no rollout found for thread id gone"))
  #expect(await eventually { bench.fakes.count == 2 && bench.fakes[1].running })
  #expect(bench.starts.map(\.resume) == ["gone", nil] && bench.fakes[0].stopped)
  #expect(bench.fakes[1].prompts.map(\.text) == ["And a semaphore?"])
  #expect(model.agent.notice == "Earlier context was not available" && model.agent.problem == nil)
  bench.fakes[1].onEvent(.session("fresh"))
  bench.fakes[1].text("A counter")
  bench.fakes[1].end()
  #expect(await eventually { !model.agent.busy })
  // The stored answers still show, and the run now resumes the new session.
  #expect(model.agent.answer == "A counter" && model.agent.previous.map(\.answer) == ["A lock"])
  #expect(bench.runs.runs.first?.session == "fresh" && bench.runs.runs.first?.turns.count == 2)
  // The next follow-up resumes it, and the line is gone.
  model.send("Which is faster?")
  #expect(await eventually { bench.fakes.count == 3 && bench.fakes[2].running })
  #expect(bench.starts.last?.resume == "fresh" && model.agent.notice == nil)
  bench.fakes[2].end()
  #expect(await eventually { !model.agent.busy })
  await bench.finish()
}

@MainActor @Test func aFailureAfterTheSessionResumedIsShownAndNotRetried() async throws {
  let bench = try Bench()
  let model = bench.model
  bench.runs.save(run("r1", [("Question", "Answer")], session: "kept"))
  try await bench.reopen("Question")
  model.send("Follow-up")
  #expect(await eventually { bench.fakes.first?.running == true })
  bench.fakes[0].onEvent(.session("kept"))
  bench.fakes[0].onEvent(.failed("Rate limited"))
  #expect(await eventually { !model.agent.busy })
  #expect(bench.fakes.count == 1 && model.agent.problem == "Rate limited" && model.agent.notice == nil)
  await bench.finish()
}

@MainActor @Test func theAddressOpensAgentHistoryButALinkNeverReopensARun() async throws {
  let bench = try Bench()
  let model = bench.model
  bench.runs.save(run("r1", [("Question", "Answer")]))
  model.go(try #require(Address(url: URL(string: "wicket://history?input=quest")!)))
  await model.settled()
  #expect(model.command?.id == "history" && model.input == "quest" && model.results.count == 1)
  // An outsider cannot spell the open argument, and an unchosen request never opens anything.
  model.go(Address(extensionName: "history", arguments: ["open": "r1"]))
  await model.settled()
  #expect(!model.agent.active && model.command?.id == "history")
  #expect(Address.reserved.contains("history"))
  await bench.finish()
}

/// What each CLI answered to an unknown session in a live check (16 Nov 2026, Claude Code 2.1.325 and
/// codex-cli 0.167.1): a failure before any session, which is what starts the question afresh.
@Test func bothCLIsReportAnUnknownSessionAsAFailureBeforeAnySession() throws {
  var claude = ClaudeTranslator()
  let claudeEvents = feed(
    &claude,
    [
      try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
          #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"gone","errors":["No conversation found with session ID: gone"]}"#
            .utf8))
    ]
  ).events
  #expect(claudeEvents == [.failed("No conversation found with session ID: gone")])
  let settings = codexSettings()
  var codex = CodexTranslator(folder: URL(fileURLWithPath: "/tmp"), resume: "gone", settings: settings)
  _ = codex.start()
  _ = codex.prompt("Follow-up", settings: settings)
  let codexEvents = feed(
    &codex,
    [
      .object(
        "id", .number(3), "error",
        .object("code", .number(-32600), "message", .string("no rollout found for thread id gone")))
    ]
  ).events
  #expect(codexEvents == [.failed("no rollout found for thread id gone")])
}
