import Foundation
import Testing

@testable import WicketApp

private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

@MainActor @Test func aRunLogsItsHeaderEveryLineBothWaysStderrAndHowItEnded() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let log = AgentLog(folder: folder.appending(path: "Logs"))
  var settings = codexSettingsForLog()
  settings.model = "gpt-6.1-terra"
  let command = ["/usr/bin/python3", fixtureURL("cli-peer.py").path, fixtureURL("codex-allow.jsonl").path]
  let run = log.begin(settings, command: command, folder: folder)
  let lines = try JSONLines(command: command, folder: folder, log: run)
  let translator = CodexTranslator(folder: folder, resume: nil, settings: settings)
  let link = AgentLink(translator, lines: lines, log: run)
  var finished = false
  link.onEvent = { event in
    if case .permission(let permission) = event { link.decide(permission.id, allow: true) }
    if case .finished = event { finished = true }
  }
  link.prompt("Hi", settings: settings)
  #expect(await eventually { finished })
  await link.stop("test")
  let file = log.file
  #expect(await eventually { text(file).contains(" EXIT ") })
  let content = text(file)
  let rows = content.split(separator: "\n").map(String.init)
  let header = try #require(rows.first)
  #expect(header.contains(" RUN agent=codex model=gpt-6.1-terra effort=default mode=agent folder="))
  #expect(header.contains("command=/usr/bin/python3 "))
  #expect(rows.contains { $0.contains(" SEND ") && $0.contains("\"method\":\"initialize\"") })
  #expect(rows.contains { $0.contains(" RECV ") && $0.contains("\"method\":\"turn/completed\"") })
  // The answer to the permission went out, and the run's ending is the CLI's, not the stop's.
  #expect(rows.contains { $0.contains(" SEND ") && $0.contains("\"decision\":\"accept\"") })
  #expect(rows.filter { $0.contains(" END ") }.count == 1 && rows.contains { $0.hasSuffix(" END finished") })
  #expect(rows.last?.contains(" EXIT exited with status 0") == true)
  // Every line is "date time #run TAG ...", with one run ID throughout.
  let ids = Set(rows.compactMap { $0.split(separator: " ").dropFirst(2).first })
  #expect(ids.count == 1)
  #expect(
    rows.allSatisfy {
      $0.wholeMatch(of: #/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} #[0-9a-f]{4} [A-Z]+ .*/#) != nil
    })
}

@MainActor @Test func stderrAndAFailedStartAreLoggedAndTheLogNeverBreaksARun() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let log = AgentLog(folder: folder.appending(path: "Logs"))
  let settings = codexSettingsForLog()
  let run = log.begin(settings, command: ["sh"], folder: folder)
  let lines = try JSONLines(
    command: ["/bin/sh", "-c", "echo boom >&2; exit 3"], folder: folder, log: run)
  var reason: String?
  lines.onClose = { reason = $0 }
  #expect(await eventually { reason != nil })
  await lines.stop()
  let file = log.file
  #expect(await eventually { text(file).contains(" EXIT exited with status 3") })
  #expect(text(file).contains(" ERR boom"))
  // A log folder that cannot be written is ignored.
  let blocked = folder.appending(path: "file")
  try Data().write(to: blocked)
  let broken = AgentLog(folder: blocked.appending(path: "inside"))
  let other = broken.begin(settings, command: ["sh"], folder: folder)
  let echo = try JSONLines(command: ["/bin/cat"], folder: folder, log: other)
  var got: JSONValue?
  echo.onMessage = { got = $0 }
  echo.send(.string("still works"))
  #expect(await eventually { got == .string("still works") })
  await echo.stop()
  other.close()
}

@MainActor @Test func theLogMovesToTheOldFileOverTwoMebibytesAtTheStartOfARun() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let log = AgentLog(folder: folder)
  let settings = codexSettingsForLog()
  try Data(repeating: 65, count: AgentLog.limit + 1).write(to: log.file)
  let first = log.begin(settings, command: ["codex"], folder: folder)
  first.note("END", "one")
  first.close()
  let old = folder.appending(path: "agent.old.log")
  #expect(await eventually { text(log.file).contains(" END one") })
  #expect(try Data(contentsOf: old).count == AgentLog.limit + 1)
  #expect(text(log.file).split(separator: "\n").count == 2)
  // Under the limit the next run appends; over it again, the old file is replaced.
  let second = log.begin(settings, command: ["codex"], folder: folder)
  second.close()
  #expect(await eventually { text(log.file).split(separator: "\n").count == 3 })
  try Data(repeating: 66, count: AgentLog.limit + 1).append(to: log.file)
  let third = log.begin(settings, command: ["codex"], folder: folder)
  third.note("END", "three")
  third.close()
  #expect(await eventually { text(log.file).split(separator: "\n").count == 2 })
  #expect(text(log.file).contains(" END three") && !text(old).contains("AAAA"))
  #expect(text(old).contains("BBBB") && text(old).contains(" END one"))
}

@Test func theStandardLogIsPerEditionAndStaysInsideAnOverriddenConfigFolder() {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  #expect(
    AgentLog.standard(edition: .release, environment: [:]).file.path == home
      + "/Library/Logs/Wicket/agent.log")
  #expect(
    AgentLog.standard(edition: .dev, environment: [:]).file.path
      == home + "/Library/Logs/Wicket Dev/agent.log")
  #expect(
    AgentLog.standard(edition: .release, environment: ["WICKET_CONFIG_DIR": "/tmp/wicket-x"]).file.path
      == "/tmp/wicket-x/agent.log")
}

private func codexSettingsForLog() -> AgentConfiguration {
  var settings = AgentConfiguration()
  settings.agent = .codex
  return settings
}

extension Data {
  fileprivate func append(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: self)
  }
}
