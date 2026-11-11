import Foundation
import Testing

@testable import WicketApp

/// Real authoring, opted in explicitly. Only two named scratch-file edits can receive permission.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_LIVE_EXTENSION"] == "1"))
func realAgentWritesAnExtensionAndItRuns() async throws {
  let folder = try scratch()
  try AnswerRenderer.installFiles(in: folder)
  try ExtensionHost.installFiles(in: folder)
  let session = AgentSession(folder: folder)
  var settings = AgentConfiguration()
  settings.agent = .claude
  settings.model = "sonnet"
  settings.effort = "low"
  settings.mode = "default"
  var records: [JSONValue] = []
  func record(_ event: String, _ data: JSONValue) {
    records.append(.object("event", .string(event), "data", data))
  }
  let prompt =
    "Read extension-contract.md. Build me an extension for doubling a number: folder extensions/double, keyword double, pattern ^double [0-9]+$. Use /usr/bin/python3 and main.py, output a list row with id result, the doubled integer as title, and a copy action. Only Read and Write tools; no shell or other tools. Write only extensions/double/wicket.json and extensions/double/main.py. Stop after writing."
  record("prompt", .string(prompt))
  session.ask(prompt, settings: settings)
  let deadline = ContinuousClock.now + .seconds(120)
  do {
    while session.busy, ContinuousClock.now < deadline {
      if let permission = session.permissions.first {
        let locations = permission.paths
        let allowed = Set(
          ["wicket.json", "main.py"].map {
            folder.appending(path: "extensions/double/" + $0).resolvingSymlinksInPath().path
          })
        let allow =
          !locations.isEmpty
          && locations.allSatisfy {
            allowed.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
          }
          && permission.kind == .edit
        record("permission", .object("request", permission.raw, "allowed", .bool(allow)))
        session.decide(allow)
        try #require(allow, "Unexpected permission; denied rather than broadening access")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(!session.busy, "Authoring turn timed out")
    try #require(session.problem == nil, "\(session.status)")
    record("answer", .string(session.answer))
    await session.shutdown()
    let ext = folder.appending(path: "extensions/double")
    for name in ["wicket.json", "main.py"] {
      let source = try String(contentsOf: ext.appending(path: name), encoding: .utf8)
      record("file:" + name, .string(source))
      if name == "main.py" {
        try #require(
          !["subprocess", "__import__", "eval(", "exec(", "import os", "import socket"].contains(
            where: source.contains), "Unexpected program capability in the scratch authoring test")
      }
    }
    let output = try await cli(folder, ["--extension", "double", "--input", "double 21"])
    record("output", output.1)
    #expect(output.0 == 0 && output.1["rows"].array.first?["title"].string == "42")
    let again = try await cli(folder, ["--query", "double 9"])
    record("root-query", again.1)
    #expect(again.0 == 0 && again.1["rows"].array.first?["row"]["title"].string == "18")
    print(
      "LIVE EXTENSION: Claude sonnet/default wrote two files; double 21 -> 42; real root query double 9 -> 18. Scratch: \(folder.path)"
    )
  } catch {
    record("failure", .string(error.localizedDescription))
    await session.shutdown()
    throw error
  }
  if let path = ProcessInfo.processInfo.environment["WICKET_EXTENSION_TRANSCRIPT"] {
    let data = try records.reduce(into: Data()) {
      $0.append(try JSONEncoder().encode($1))
      $0.append(10)
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}
