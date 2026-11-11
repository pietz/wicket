import Foundation
import Testing

@testable import WicketApp

private func listed(_ agent: AgentConfiguration.Agent) throws -> [AgentModel] {
  let message = try recorded(agent.rawValue + "-models")[0]
  return try #require((agent == .claude ? ClaudeTranslator.listing : CodexTranslator.listing).models(message))
}
/// Lists models by running a recorded CLI conversation, through the real discovery code.
@MainActor private func discoverRecorded(_ agent: AgentConfiguration.Agent) async throws -> [AgentModel] {
  try await AgentDiscovery.models(
    command: [
      "/usr/bin/python3", fixtureURL("cli-peer.py").path, fixtureURL(agent.rawValue + "-models.jsonl").path,
    ],
    listing: agent == .claude ? ClaudeTranslator.listing : CodexTranslator.listing, timeout: .seconds(10))
}

@Test func defaultsAreSonnetOrTheLatestTerraLowEffortAutoAndRegular() throws {
  let claude = AgentConfiguration()
  #expect(
    ["model", "effort", "mode", "speed"].map { AgentOptions.resolved(claude, key: $0, models: []) } == [
      "sonnet", "low", "auto", "off",
    ])
  var codex = AgentConfiguration()
  codex.agent = .codex
  #expect(
    ["model", "effort", "mode", "speed"].map {
      AgentOptions.resolved(codex, key: $0, models: try! listed(.codex))
    } == ["gpt-6.1-terra", "low", "agent", "off"])
  #expect(AgentOptions.resolved(codex, key: "model", models: []) == "terra")
  codex.model = "gpt-6-astra"
  codex.mode = "read-only"
  #expect(
    AgentOptions.resolved(codex, key: "model", models: []) == "gpt-6-astra"
      && AgentOptions.resolved(codex, key: "mode", models: []) == "read-only")
}

@Test func modelTiersUseNewestReportedIDsAndUnavailableChoices() throws {
  var settings = AgentConfiguration()
  settings.agent = .codex
  let models = ["gpt-9.9-terra", "gpt-9.10-terra", "gpt-9-sol", "gpt-8-sol", "gpt-9-solar"].map {
    AgentModel(id: $0)
  }
  let choices = AgentOptions.choices(models, key: "model", for: settings)
  #expect(choices.map(\.value) == ["astra", "gpt-9-sol", "gpt-9.10-terra", "luna"])
  #expect(choices.map(\.available) == [false, true, true, false])
}

@Test func modelChoicesShowTheCLIsVersionedNames() throws {
  var settings = AgentConfiguration()
  let claude = AgentOptions.choices(try listed(.claude), key: "model", for: settings)
  #expect(
    claude.map(\.title) == ["Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]
      && claude.allSatisfy(\.available))
  #expect(claude.map(\.value) == ["fable", "opus", "sonnet", "haiku"])
  settings.agent = .codex
  let chatGPT = AgentOptions.choices(try listed(.codex), key: "model", for: settings)
  #expect(chatGPT.map(\.title) == ["GPT-6 Astra", "GPT-6.1 Sol", "GPT-6.1 Terra", "GPT-6 Luna"])
  #expect(
    chatGPT.map(\.value) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"]
      && chatGPT.allSatisfy(\.available))
}

@Test func effortSpeedAndModeChoicesFollowTheChosenModel() throws {
  var settings = AgentConfiguration()
  let models = try listed(.claude)
  func available(_ key: String) -> [String] {
    AgentOptions.choices(models, key: key, for: settings).filter(\.available).map(\.title)
  }
  #expect(available("effort") == ["Low", "Medium", "High", "Extra high"])
  #expect(available("speed") == ["Regular"] && !AgentOptions.offersFast(settings, models: models))
  settings.model = "opus"
  #expect(available("speed") == ["Regular", "Fast"] && AgentOptions.offersFast(settings, models: models))
  settings.model = "claude-haiku-4-5-20251001"
  #expect(available("effort").isEmpty)
  settings.model = "sonnet"
  settings.speed = "on"
  #expect(AgentOptions.offersFast(settings, models: models))
  let modes = AgentOptions.choices(models, key: "mode", for: settings)
  #expect(modes.map(\.title) == ["Supervised", "Auto-accept edits", "Auto", "Full access"])
  #expect(modes.map(\.value) == ["default", "acceptEdits", "auto", "bypassPermissions"])
  settings.agent = .codex
  #expect(
    AgentOptions.choices([], key: "mode", for: settings).map(\.value) == [
      "read-only", "workspace-write", "agent", "agent-full-access",
    ])
  #expect(AgentOptions.choices([], key: "speed", for: settings).first?.available == true)
}

@MainActor @Test func discoveryCachesBothAgentsRefreshesStaleReportsAndIgnoresOldFormats() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  // A report from the ACP adapters has another shape. It reads as missing.
  try Data(#"{"configOptions":[{"id":"model"}],"updated":\#(Date().timeIntervalSince1970)}"#.utf8)
    .write(to: AgentDiscovery.url(.claude, in: folder))
  let store = ConfigurationStore(url: folder.appending(path: "config.json"))
  store.start()
  #expect(store.models.isEmpty)
  var agents: [AgentConfiguration.Agent] = []
  store.discover = { agent in
    agents.append(agent)
    return try await discoverRecorded(agent)
  }
  // Sign-in is checked with the options and remembered; questions never wait for it.
  store.checkSignIn = { $0 == .claude ? .signedIn : .signedOut }
  store.discoverOptions()
  store.discoverOptions()
  #expect(await eventually { store.catalogs.count == 2 })
  #expect(await eventually { store.signIn == [.claude: .signedIn, .codex: .signedOut] })
  #expect(Set(agents) == Set(AgentConfiguration.Agent.allCases))
  await store.discovery?.value
  store.discoverOptions()
  await store.discovery?.value
  #expect(agents.count == 2)
  #expect(store.models.contains { $0.id == "sonnet" })
  #expect(store.change { try $0.selectAgent("codex") })
  #expect(await eventually { store.configuration.agent.agent == .codex })
  #expect(store.models.contains { $0.id == "gpt-6.1-terra" })
  // A report older than an hour is refreshed.
  try JSONEncoder().encode(AgentCatalog(models: [], updated: 0)).write(
    to: AgentDiscovery.url(.claude, in: folder), options: .atomic)
  #expect(await eventually { store.catalogs[.claude]?.models.isEmpty == true })
  store.discoverOptions()
  #expect(await eventually { store.catalogs[.claude]?.models.isEmpty == false })
  #expect(agents.count == 3)
}

@MainActor @Test func discoveryTimeoutStopsTheCLIAndKeepsSavedValues() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = ConfigurationStore(url: folder.appending(path: "config.json"))
  store.start()
  #expect(await eventually { FileManager.default.fileExists(atPath: store.url.path) })
  #expect(store.change { try $0.set("model", to: "saved-model", in: "agent") })
  let pidFile = folder.appending(path: "pid")
  store.checkSignIn = { _ in .unknown }
  store.discover = { agent in
    try await AgentDiscovery.models(
      command: [
        "/usr/bin/python3", "-c",
        "import os,sys,time; open(sys.argv[1],'a').write(str(os.getpid())+'\\n'); sys.stdin.readline(); time.sleep(60)",
        pidFile.path,
      ],
      listing: ClaudeTranslator.listing, timeout: .milliseconds(150))
  }
  store.discoverOptions()
  #expect(await eventually { store.discoveryStatus["codex"]?.contains("Timed out") == true })
  #expect(store.configuration.agent.model == "saved-model")
  let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
  #expect(pids.count == 2)
  #expect(await eventually { pids.allSatisfy { kill($0, 0) != 0 } })
  // A CLI that ends or lists nothing says so.
  await #expect(throws: AgentFailure.self) {
    try await AgentDiscovery.models(
      command: ["/usr/bin/false"], listing: ClaudeTranslator.listing, timeout: .seconds(5))
  }
  await #expect(throws: AgentFailure.self) {
    try await AgentDiscovery.models(
      command: ["/usr/bin/python3", fixtureURL("cli-peer.py").path, fixtureURL("claude-allow.jsonl").path],
      listing: Listing(arguments: [], send: [], models: { _ in [] }), timeout: .seconds(5))
  }
}

@MainActor @Test func slowOtherAgentDoesNotDelaySelectedAgentDiscovery() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigurationStore(url: root.appending(path: "config.json"))
  store.start()
  #expect(store.change { try $0.selectAgent("codex") })
  #expect(await eventually { store.configuration.agent.agent == .codex })
  let (blocked, release) = AsyncStream.makeStream(of: Void.self)
  var started: Set<AgentConfiguration.Agent> = []
  store.checkSignIn = { _ in .unknown }
  store.discover = { agent in
    started.insert(agent)
    if agent == .claude { for await _ in blocked {} }
    return try listed(agent)
  }
  store.discoverOptions()
  #expect(await eventually { store.catalogs[.codex] != nil })
  #expect(started == Set(AgentConfiguration.Agent.allCases) && store.catalogs[.claude] == nil)
  release.finish()
  await store.discovery?.value
  #expect(store.catalogs.count == 2)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_DISCOVER_OPTIONS"] == "1"))
func realCLIModelListingWithoutPrompt() async throws {
  for agent in [AgentConfiguration.Agent.claude, .codex] {
    let models = try await AgentDiscovery.discover(agent)
    print(
      "DISCOVERY ", agent.title, models.map { "\($0.id) (\($0.name)) efforts=\($0.efforts) fast=\($0.fast)" })
  }
}

@MainActor @Test func nonStreamingAnswersPublishOnlyAtMessageToolCompletionAndFailureBoundaries() async throws
{
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeAgent()
  let session = AgentSession(folder: folder)
  session.connect = { _, _, _ in fake }
  var settings = AgentConfiguration()
  settings.streamAnswers = false
  session.ask("Buffered", settings: settings)
  #expect(await eventually { fake.running })
  var changes = 0
  session.onChange = { changes += 1 }
  fake.text("First ")
  let started = changes
  fake.text("message")
  #expect(session.answer.isEmpty && changes == started)
  fake.tool("Search the web")
  #expect(session.answer == "First message" && session.status == "Search the web")
  fake.text("Second message", message: "a")
  #expect(session.answer == "First message")
  fake.text("Final ", message: "b")
  #expect(session.answer == "First message\n\nSecond message")
  fake.text("answer", message: "b")
  let before = changes
  fake.end()
  #expect(await eventually { !session.busy })
  #expect(session.answer == "First message\n\nSecond message\n\nFinal answer" && changes == before + 1)
  session.ask("Failure", settings: settings)
  #expect(await eventually { fake.running })
  fake.text("Partial answer")
  fake.onEvent(.failed("Failed"))
  #expect(await eventually { !session.busy })
  #expect(session.answer == "Partial answer" && session.problem == "Failed")
  await session.shutdown()
}

@MainActor @Test func bufferedAnswerLimitIncludesPreviouslyPublishedMessages() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeAgent()
  let session = AgentSession(folder: root)
  session.connect = { _, _, _ in fake }
  var config = AgentConfiguration()
  config.streamAnswers = false
  session.ask("Bound the whole answer", settings: config)
  #expect(await eventually { fake.running })
  fake.text(String(repeating: "a", count: 600_000))
  fake.tool("step")
  fake.text(String(repeating: "b", count: 500_000))
  #expect(await eventually { !session.busy })
  #expect(session.problem == "Answer reached the 1 MB limit" && session.answer.utf8.count == 600_000)
  await session.shutdown()
}
