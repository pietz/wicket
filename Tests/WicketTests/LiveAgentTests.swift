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
  let session = AgentSession(folder: folder)
  try AnswerRenderer.installFiles(in: folder)
  var settings = AgentConfiguration()
  settings.agent = name == "claude" ? .claude : .codex
  settings.model = name == "claude" ? "sonnet" : "gpt-6.1-sol"
  settings.effort = "low"
  settings.mode = name == "claude" ? "default" : "read-only"
  settings.streamAnswers = true
  func wait(_ condition: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(90)
    while !condition(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition(), "\(name): \(session.status)")
  }
  do {
    session.ask(
      "Remember the codeword LANTERN-47 for this conversation. Reply only LANTERN-47. No tools.",
      settings: settings)
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47"), "\(name): \(session.status)")
    let id = try #require(session.sessionID)
    session.ask("What is the codeword? Reply only the codeword. No tools.", settings: settings)
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47"), "\(name): \(session.status)")
    #expect(session.sessionID == id)
    // A changed model, effort or mode applies on the next question's launch.
    settings.effort = "medium"
    settings.model = name == "claude" ? "haiku" : "gpt-6-luna"
    session.ask("What is the codeword? Reply only the codeword. No tools.", settings: settings)
    try await wait { !session.busy }
    #expect(session.answer.contains("LANTERN-47") && session.sessionID == id, "\(name): \(session.status)")
    settings.effort = "low"
    settings.model = name == "claude" ? "sonnet" : "gpt-6.1-sol"
    // The default modes must require permission. Only an explicitly scoped scratch write is allowed.
    session.ask(
      "Use the file-writing tool to create \(folder.path)/allowed.txt containing exactly ALLOWED. Do not run shell commands or touch any other path.",
      settings: settings)
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
    session.ask(
      "Use the file-writing tool to create \(folder.path)/denied.txt containing DENIED. Do not run shell commands or touch any other path.",
      settings: settings)
    try await wait { !session.permissions.isEmpty || !session.busy }
    _ = try #require(session.permissions.first)
    session.decide(false)
    try await wait { !session.busy }
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "denied.txt").path))
    session.ask("Count the integers 1 to 5000, one per line, without tools.", settings: settings)
    try await wait { !session.answer.isEmpty || !session.busy }
    session.cancel()
    try await wait { !session.busy }
    #expect(session.status == "Cancelled")
    print(
      "LIVE \(name): stream, resume/history, settings change, allow, deny, cancel passed; scratch \(folder.path)"
    )
    await session.shutdown()
  } catch {
    await session.shutdown()
    throw error
  }
}
