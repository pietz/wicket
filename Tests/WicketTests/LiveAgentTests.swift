import Foundation
import Testing

@testable import WicketApp

/// Explicit opt-in. Runs the installed claude and codex in a fresh scratch folder, never AppKit UI.
@MainActor
@Test(
  .enabled(if: ProcessInfo.processInfo.environment["WICKET_LIVE_AGENT"] == "1"),
  arguments: ["claude", "codex"])
func liveAgentScratchConversation(_ name: String) async throws {
  let folder = try scratch()
  let model = try liveScratchModel(in: folder)
  let session = model.agent
  var settings = AgentConfiguration()
  settings.agent = name == "claude" ? .claude : .codex
  settings.model = name == "claude" ? "sonnet" : "gpt-6.1-sol"
  settings.effort = "low"
  settings.mode = name == "claude" ? "default" : "read-only"
  settings.streamAnswers = true
  func ask(_ question: String) {
    model.store.update { $0.agent = settings }
    model.navigator.send(question)
  }
  func wait(_ condition: () -> Bool) async throws {
    try #require(try await waitForLiveAgent(until: .seconds(90), condition), "\(name): \(session.status)")
  }
  do {
    ask("Remember the codeword LANTERN-47 for this conversation. Reply only LANTERN-47. No tools.")
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47"), "\(name): \(session.status)")
    let id = try #require(session.sessionID)
    ask("What is the codeword? Reply only the codeword. No tools.")
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47"), "\(name): \(session.status)")
    #expect(session.sessionID == id)
    // A changed model, effort or mode applies on the next question's launch.
    settings.effort = "medium"
    settings.model = name == "claude" ? "haiku" : "gpt-6-luna"
    ask("What is the codeword? Reply only the codeword. No tools.")
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47") && session.sessionID == id, "\(name): \(session.status)")
    settings.effort = "low"
    settings.model = name == "claude" ? "sonnet" : "gpt-6.1-sol"
    // The default modes must require permission. Only an explicitly scoped scratch write is allowed.
    ask(
      "Use the file-writing tool to create \(folder.path)/allowed.txt containing exactly ALLOWED. Do not run shell commands or touch any other path."
    )
    try await wait { !session.permissions.isEmpty || !session.busy }
    let permission = try #require(
      session.permissions.first, "\(name): no permission: \(session.status)")
    // A file edit names its files; a command names itself.
    let named = permission.paths.isEmpty ? [permission.command ?? ""] : permission.paths
    try #require(named.allSatisfy { $0.contains(folder.path + "/") }, "\(name): \(permission)")
    session.decide(true)
    try await wait { !session.busy || !session.permissions.isEmpty }
    try #require(
      session.permissions.isEmpty, "Unexpected additional permission; no automatic allow")
    #expect(
      try String(contentsOf: folder.appending(path: "allowed.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == "ALLOWED")
    ask(
      "Use the file-writing tool to create \(folder.path)/denied.txt containing DENIED. Do not run shell commands or touch any other path."
    )
    try await wait { !session.permissions.isEmpty || !session.busy }
    _ = try #require(session.permissions.first)
    session.decide(false)
    try await wait { !session.busy }
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "denied.txt").path))
    ask("Count the integers 1 to 5000, one per line, without tools.")
    try await wait { !session.answer.isEmpty || !session.busy }
    session.cancel()
    try await wait { !session.busy }
    #expect(session.status == "Cancelled")
    print(
      "LIVE \(name): stream, resume/history, settings change, allow, deny, cancel passed; scratch \(folder.path)"
    )
    await model.finish()
  } catch {
    await model.finish()
    throw error
  }
}

@MainActor
func liveScratchModel(in folder: URL, instructionTemplate: String? = nil) throws -> LauncherModel {
  try AnswerRenderer.installFiles(in: folder)
  let model = LauncherModel.testing(in: folder, bundled: nil)
  let log = AgentLog(folder: folder.appending(path: "logs"))
  model.agent.connect = {
    try AgentCLI.connect($0, folder: $1, resume: $2, log: log, instructionTemplate: instructionTemplate)
  }
  return model
}

@MainActor
func waitForLiveAgent(until timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
  return condition()
}

/// Codex's Auto mode (a reviewer subagent decides) never sends turn/completed: a plain question and
/// a scratch-file edit must both end, with any permission reaching Wicket.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_LIVE_AGENT"] == "1"))
func liveCodexAutoModeEndsItsTurns() async throws {
  let folder = try scratch()
  let logs = folder.appending(path: "logs")
  let session = AgentSession(folder: folder, log: AgentLog(folder: logs))
  var settings = AgentConfiguration()
  settings.agent = .codex
  settings.model = "gpt-6.1-sol"
  settings.effort = "low"
  settings.mode = "agent"
  do {
    session.ask("Reply only OK. No tools.", settings: settings)
    try await finish(session)
    #expect(session.answer.contains("OK") && session.problem == nil, "\(session.status)")
    session.ask(
      "Use the file-writing tool to create \(folder.path)/auto.txt containing exactly AUTO. Do not touch any other path.",
      settings: settings)
    let asked = try await finish(session, allowing: true)
    #expect(session.problem == nil, "\(session.status)")
    #expect(
      try String(contentsOf: folder.appending(path: "auto.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == "AUTO")
    print("LIVE codex auto: plain and file edit ended (permission asked \(asked)x); log \(logs.path)")
    await session.shutdown()
  } catch {
    await session.shutdown()
    throw error
  }
}

/// Waits for the turn to end, allowing every permission asked if told to. Returns how many were asked.
@MainActor @discardableResult
private func finish(_ session: AgentSession, allowing: Bool = false) async throws -> Int {
  var asked = 0
  let until = ContinuousClock.now + .seconds(120)
  while session.busy, ContinuousClock.now < until {
    if allowing, !session.permissions.isEmpty {
      asked += 1
      session.decide(true)
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(!session.busy, "turn never ended: \(session.status)")
  return asked
}
