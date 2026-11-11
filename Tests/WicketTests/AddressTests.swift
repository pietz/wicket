import Foundation
import Testing

@testable import WicketApp

private func action(_ json: String) throws -> RowAction {
  try JSONDecoder().decode(RowAction.self, from: Data(json.utf8))
}

private func url(_ text: String) -> Address? { Address(url: URL(string: text)!) }

@Test func anAddressDecodesFromJSONAndFromAURL() throws {
  #expect(
    try action(#"{"type":"run","extension":"weather","input":"berlin","arguments":["hourly"]}"#)
      == .run(Address(extensionName: "weather", input: "berlin", arguments: ["hourly"])))
  // Today's run action, and a run with nothing to say, keep working: omitted means this one, as now.
  #expect(try action(#"{"type":"run","arguments":["refresh"]}"#) == .run(Address(arguments: ["refresh"])))
  #expect(try action(#"{"type":"run"}"#) == .run(Address()))
  #expect(try action(#"{"type":"agent","text":"Why?"}"#) == .agent("Why?"))
  let sent = Address(extensionName: "weather", input: "berlin", arguments: ["hourly"])
  #expect(
    try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(RowAction.run(sent))) == .run(sent))
  #expect(throws: (any Error).self) { try action(#"{"type":"run","arguments":"hourly"}"#) }

  #expect(url("wicket://weather?input=berlin") == Address(extensionName: "weather", input: "berlin"))
  #expect(url("wicket://weather?input=a%20b%26c") == Address(extensionName: "weather", input: "a b&c"))
  #expect(url("wicket://weather") == Address(extensionName: "weather"))
  #expect(url("wicket://?input=x") == Address(input: "x"))
  #expect(url("wicket://") == Address())
  #expect(url("wicket:weather?input=x") == Address(extensionName: "weather", input: "x"))
  #expect(url("wicket://agent?input=Why") == Address(extensionName: "agent", input: "Why"))
  #expect(url("wicket://settings")?.targetID == "settings")
  #expect(url("wicket-dev://weather?input=x") == Address(extensionName: "weather", input: "x"))
  #expect(url("https://weather?input=x") == nil && url("wicketx://weather") == nil)
  // Reserved targets win, an extension name is spelled with or without its prefix, and case is kept.
  #expect(Address(extensionName: "Agent").targetID == "agent")
  #expect(Address(extensionName: "weather").targetID == "extension:weather")
  #expect(Address(id: "extension:weather").targetID == "extension:weather")
  #expect(Address(extensionName: "extension:weather").targetID == "extension:weather")
  #expect(Address(extensionName: "").targetID == nil)

  // An open action with a wicket URL is an address too, and the host's own actions are never decoded.
  #expect(
    try action(#"{"type":"open","url":"wicket://weather?input=x"}"#)
      == .run(Address(extensionName: "weather", input: "x")))
  for json in [#"{"type":"ask","text":"x"}"#, #"{"type":"report","text":"x"}"#] {
    #expect(throws: (any Error).self) { try action(json) }
  }
}

@Test func outsidersNameATargetAndAnInputButNeverArguments() throws {
  // A URL has no way to carry arguments: a query item of that name is ignored.
  let outside = url("wicket://deploy?input=prod&arguments=%5B%22delete%22%5D&extension=other")
  #expect(outside == Address(extensionName: "deploy", input: "prod") && outside?.arguments == nil)
  // The same goes for what an agent writes: its items and the links in its text.
  let view = ProviderView(
    reply: #"<item title="Open" open="wicket://deploy?input=prod&arguments=%5B%22delete%22%5D"/>"#
      + #"<item title="Root" open="wicket://?input=hello"/><item title="Why" ask="Why?"/>"#)
  #expect(
    view.items.map(\.actions) == [
      [.run(Address(extensionName: "deploy", input: "prod"))], [.run(Address(input: "hello"))],
      [.agent("Why?")],
    ])
  #expect(view.items.allSatisfy { $0.actions.count == 1 })
  #expect(AnswerLink.allowed(URL(string: "wicket://deploy?input=x")))
  // The wire has no spelling that gives a URL arguments, whichever action carries it.
  #expect(
    try action(#"{"type":"open","url":"wicket://deploy?input=x&arguments=%5B%22a%22%5D"}"#)
      == .run(Address(extensionName: "deploy", input: "x")))
}

@MainActor @Test func everyRowTheHostSynthesizesDispatchesThroughItsAction() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let page = String(
    decoding: try JSONEncoder().encode(ProviderView(body: "## Details")), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "ship", script: answering("Ready"),
    fields: ["name": "Ship", "keyword": "ship", "fallback": true])
  _ = try extensionFolder(
    root, name: "page", script: "cat >/dev/null\nprintf '%s' '\(page)'",
    fields: ["name": "Page", "keyword": "page", "match": "^page"])
  _ = try extensionFolder(
    root, name: "broken", script: "echo REPAIR >&2; echo '{bad'", fields: ["match": "^broken"])
  try Data("{}".utf8).write(
    to: {
      let folder = root.appending(path: "extensions/invalid")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return folder.appending(path: "wicket.json")
    }())
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  var settings = 0
  model.onSettings = { settings += 1 }
  await model.extensions.reload()

  /// Selects the row and presses Return, which is the only way in.
  func press(_ input: String, _ pick: (Result) -> Bool) async throws {
    _ = model.escape()
    model.input = input
    await model.settled()
    let row = try #require(model.results.first { pick($0) }, Comment(rawValue: input))
    #expect(row.row.actions.count == 1)
    model.select(row.id)
    #expect(model.activateReturn())
    await model.settled()
  }

  // Name match: the command row enters with empty input.
  try await press("sh") { $0.row.id == "command" }
  #expect(model.command?.id == "extension:ship" && model.input == "")
  // Fallback: enters with the root query kept.
  try await press("an unrelated sentence") { $0.row.id == "fallback" }
  #expect(model.command?.id == "extension:ship" && model.input == "an unrelated sentence")
  // A pattern result with a body: enters with the query kept and shows the body.
  try await press("page one") { $0.row.id == "detail" }
  #expect(model.command?.id == "extension:page" && model.input == "page one" && model.body == "## Details")
  // A failed pattern: the error row shows the report.
  try await press("broken now") { $0.row.id == "error" }
  #expect(model.command?.id == "extension:broken" && model.command?.problem?.contains("REPAIR") == true)
  // An invalid manifest: the repair row fills the input with the brief and sends nothing.
  try await press("zzz") { $0.row.id == "discovery-error" }
  #expect(model.input.contains("Invalid wicket.json") && model.command == nil && !model.agent.active)
  // Settings.
  try await press("settings") { $0.provider == "settings" }
  #expect(settings == 1)
  // Ask agent sends the question.
  try await press("Where is the moon?") { $0.provider == "agent" }
  #expect(await eventually { fake.running })
  #expect(model.agent.question == "Where is the moon?")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.agent.reset()

  // Nothing the root list shows is without an action.
  model.input = "ship"
  await model.settled()
  #expect(!model.results.isEmpty && model.results.allSatisfy { !$0.row.actions.isEmpty })
  await model.finish()
}

@MainActor @Test func anAddressOpensAnotherExtensionTheRootOrTheAgentAndKeepsTypedInputInTheSameCommand()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let echo =
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':'/'.join(r['arguments'])+':'+r['input']}))"
  for name in ["one", "two"] {
    let folder = try extensionFolder(root, name: name, fields: ["command": ["/usr/bin/python3", "echo.py"]])
    try Data(echo.utf8).write(to: folder.appending(path: "echo.py"))
  }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  // An extension's own row may name another extension with arguments.
  model.go(Address(extensionName: "two", input: "x", arguments: ["a", "b"]), from: "extension:one")
  await model.settled()
  #expect(model.command?.id == "extension:two" && model.body == "a/b:x")
  // Without a target it is this one, and without an input the typed one stays.
  model.go(Address(arguments: ["c"]), from: "extension:two")
  await model.settled()
  #expect(model.command?.id == "extension:two" && model.body == "c:x")
  // Entering another extension without an input starts empty.
  model.go(Address(id: "extension:one"))
  await model.settled()
  #expect(model.command?.id == "extension:one" && model.body == ":")
  // An unknown extension changes nothing and says so.
  model.go(Address(extensionName: "nothing", input: "x"))
  #expect(model.command?.id == "extension:one" && model.actionProblem?.contains("nothing") == true)
  // No target is a root query, and `agent` only fills the input.
  model.go(Address(input: "calc"))
  #expect(model.command == nil && model.input == "calc")
  model.go(Address(extensionName: "agent", input: "Why?"), from: "extension:one")
  #expect(model.input == "Why?" && !model.agent.active && !model.agent.busy)
  await model.finish()
}

@Test func plainStdoutIsAMarkdownBodyAndBrokenJSONStaysAnError() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  func run(_ script: String) async throws -> ProviderView {
    let folder = try extensionFolder(root, name: "plain", script: script)
    return try await ExtensionRunner().run(command(folder), request: .init(input: ""))
  }
  let markdown = try await run("printf '## Done\\n<stat label=\"Total\" value=\"42\"/>\\n'")
  #expect(markdown.body == "## Done\n<stat label=\"Total\" value=\"42\"/>" && markdown.items.isEmpty)
  // The reply parser also reads its item tags, with the outsider rules.
  let tagged = try await run(
    "printf 'See <item title=\"Docs\" open=\"https://example.com\"/>'")
  #expect(tagged.body == "See" && tagged.items.map(\.title) == ["Docs"])
  // JSON, even after whitespace, is still a view.
  #expect(try await run("printf '\\n  {\"body\":\"json\"}'") == ProviderView(body: "json"))
  for broken in [
    "echo '{bad'", "echo '{\"items\":['", "echo '{\"body\":1}'", "echo '{}'", "echo",
    "printf ' \\n'",
  ] {
    await #expect(throws: (any Error).self, Comment(rawValue: broken)) { _ = try await run(broken) }
  }
}

@Test func headlessQueryShowsTheRealActionOfEveryRow() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "deploy", script: answering("Ready"), fields: ["keyword": "ship"])
  try saveProviders([.init("extension:deploy")], in: root)
  let output = try await cli(root, ["--query", "ship"])
  let rows = output.1["items"].array
  let command = try #require(rows.first { $0["row"]["id"].string == "command" })
  #expect(command["row"]["actions"].array.first?["type"].string == "run")
  #expect(command["row"]["actions"].array.first?["extension"].string == "deploy")
  #expect(command["row"]["actions"].array.first?["input"].string == "")
  let ask = try #require(rows.first { $0["provider"].string == "agent" })
  #expect(ask["row"]["actions"].array.first?["type"].string == "ask")
  #expect(ask["row"]["actions"].array.first?["text"].string == "ship")
}
