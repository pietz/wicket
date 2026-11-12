import Foundation
import Testing

@testable import WicketApp

private func action(_ json: String) throws -> RowAction {
  try JSONDecoder().decode(RowAction.self, from: Data(json.utf8))
}

private func url(_ text: String) -> Address? { Address(url: URL(string: text)!) }

/// The address a URL spells: a link, never with arguments.
private func link(_ name: String, _ input: String? = nil) -> Address {
  Address(extensionName: name, input: input, link: true)
}

@Test func anAddressDecodesFromJSONAndFromAURL() throws {
  #expect(
    try action(#"{"type":"run","extension":"weather","input":"berlin","arguments":{"view":"hourly"}}"#)
      == .run(Address(extensionName: "weather", input: "berlin", arguments: ["view": "hourly"])))
  // Omitted means this one, as now; an empty object is no arguments, said explicitly.
  #expect(try action(#"{"type":"run","arguments":{"id":"42"}}"#) == .run(Address(arguments: ["id": "42"])))
  #expect(try action(#"{"type":"run","arguments":{}}"#) == .run(Address(arguments: [:])))
  #expect(try action(#"{"type":"run"}"#) == .run(Address()))
  #expect(try action(#"{"type":"agent","text":"Why?"}"#) == .agent("Why?"))
  let sent = Address(
    extensionName: "weather", input: "berlin", arguments: ["view": "hourly", "city": "berlin"])
  #expect(
    try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(RowAction.run(sent))) == .run(sent))
  #expect(throws: (any Error).self) { try action(#"{"type":"run","arguments":"hourly"}"#) }
  #expect(throws: (any Error).self) { try action(#"{"type":"run","arguments":{"n":1}}"#) }
  // The positional array is gone: it is a decoding error with its path, like any malformed view.
  do {
    _ = try JSONDecoder().decode(
      ProviderView.self,
      from: Data(
        #"{"items":[{"id":"a","title":"A","actions":[{"type":"run","arguments":["hourly"]}]}]}"#.utf8))
    Issue.record("An array of arguments decoded")
  } catch let DecodingError.typeMismatch(_, context) {
    #expect(context.codingPath.map(\.stringValue) == ["items", "Index 0", "actions", "Index 0", "arguments"])
  }
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(ProviderRequest.self, from: Data(#"{"input":"","arguments":["a"]}"#.utf8))
  }

  #expect(url("wicket://weather?input=berlin") == link("weather", "berlin"))
  #expect(url("wicket://weather?input=a%20b%26c") == link("weather", "a b&c"))
  #expect(url("wicket://weather") == link("weather"))
  #expect(url("wicket://?input=x") == link("", "x"))
  #expect(url("wicket://") == link(""))
  #expect(url("wicket:weather?input=x") == link("weather", "x"))
  #expect(url("wicket://agent?input=Why") == link("agent", "Why"))
  #expect(url("wicket://settings")?.targetID == "settings")
  #expect(url("wicket-dev://weather?input=x") == link("weather", "x"))
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
      == .run(link("weather", "x")))
  #expect(throws: (any Error).self) { try action(#"{"type":"send","text":"x"}"#) }
}

@Test func everyActionKindTakesATitleThatNamesItInMenus() throws {
  let titled = [
    #"{"type":"open","url":"https://example.com","title":"Website"}"#,
    #"{"type":"reveal","url":"file:///tmp","title":"Show folder"}"#,
    #"{"type":"copy","text":"42","title":"Copy total"}"#,
    #"{"type":"paste","text":"42","title":"Paste total"}"#,
    #"{"type":"run","arguments":{"id":"42"},"title":"Delete"}"#,
    #"{"type":"agent","text":"Why?","title":"Ask why"}"#,
  ]
  for json in titled {
    let decoded = try action(json)
    #expect(decoded.title != nil && decoded.label == decoded.title)
    #expect(try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(decoded)) == decoded)
  }
  #expect(try action(#"{"type":"open","url":"wicket://weather","title":"Weather"}"#).label == "Weather")
  // Without a title each kind keeps its label; a run is Run for this command and Open elsewhere.
  #expect(try action(#"{"type":"run","arguments":{"id":"42"}}"#).label == "Run")
  #expect(try action(#"{"type":"run","extension":"weather"}"#).label == "Open")
  #expect(try action(#"{"type":"open","url":"wicket://?input=x"}"#).label == "Open")
  #expect(try action(#"{"type":"agent","text":"Why?"}"#).label == "Ask agent…")
  #expect(try action(#"{"type":"copy","text":"42"}"#).label == "Copy")
  // A title is encoded only when there is one.
  #expect(
    String(decoding: try JSONEncoder().encode(RowAction.copy("x")), as: UTF8.self).contains("title") == false)
}

@Test func outsidersNameATargetAndAnInputButNeverArguments() throws {
  // A URL has no way to carry arguments: a query item of that name is ignored.
  let outside = url("wicket://deploy?input=prod&arguments=%7B%22a%22%3A%22b%22%7D&extension=other")
  #expect(outside == link("deploy", "prod") && outside?.arguments == nil)
  // The same goes for what an agent writes: its items and the links in its text.
  let view = ProviderView(
    reply: #"<item title="Open" open="wicket://deploy?input=prod&arguments=%5B%22delete%22%5D"/>"#
      + #"<item title="Root" open="wicket://?input=hello"/><item title="Why" ask="Why?"/>"#)
  #expect(
    view.items.map(\.actions) == [
      [.run(link("deploy", "prod"))],
      [.run(link("", "hello"))],
      [.agent("Why?")],
    ])
  #expect(view.items.allSatisfy { $0.actions.count == 1 })
  #expect(AnswerLink.allowed(URL(string: "wicket://deploy?input=x")))
  // The wire has no spelling that gives a URL arguments, whichever action carries it.
  #expect(
    try action(#"{"type":"open","url":"wicket://deploy?input=x&arguments=%5B%22a%22%5D"}"#)
      == .run(link("deploy", "x")))
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
  // A failed pattern: the error row enters the command with the query kept, which runs it again and
  // shows the failure with its report, where the header offers Ask agent.
  try await press("broken now") { $0.row.id == "error" }
  #expect(model.command?.id == "extension:broken" && model.input == "broken now")
  let problem = try #require(model.command?.problem)
  #expect(problem.contains("REPAIR") && problem.contains("Command:") && problem.contains("broken now"))
  // An invalid manifest: the repair row drafts the brief in an empty conversation and sends nothing.
  try await press("zzz") { $0.row.id == "discovery-error" }
  #expect(model.input.contains("Invalid wicket.json") && model.command == nil)
  #expect(model.agent.active && !model.agent.busy && model.agent.question.isEmpty)
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
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':'/'.join(sorted(r['arguments'].values()))+':'+r['input']}))"
  for name in ["one", "two"] {
    let folder = try extensionFolder(root, name: name, fields: ["command": ["/usr/bin/python3", "echo.py"]])
    try Data(echo.utf8).write(to: folder.appending(path: "echo.py"))
  }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  // An extension's own row may name another extension with arguments.
  model.go(Address(extensionName: "two", input: "x", arguments: ["p": "a", "q": "b"]), from: "extension:one")
  await model.settled()
  #expect(model.command?.id == "extension:two" && model.body == "a/b:x")
  // Without a target it is this one, and without an input the typed one stays.
  model.go(Address(arguments: ["p": "c"]), from: "extension:two")
  await model.settled()
  #expect(model.command?.id == "extension:two" && model.body == "c:x")
  // Entering another extension without an input starts empty.
  model.go(Address(id: "extension:one"))
  await model.settled()
  #expect(model.command?.id == "extension:one" && model.body == ":")
  // An unknown extension changes nothing and says so.
  model.go(Address(extensionName: "nothing", input: "x"))
  #expect(model.command?.id == "extension:one" && model.actionProblem?.contains("nothing") == true)
  // No target is a root query.
  model.go(Address(input: "calc"))
  #expect(model.command == nil && model.input == "calc")
  // A root URL stays the root even from an extension's own row, where an omitted target is that one.
  try model.go(#require(url("wicket://two?input=y")), from: "extension:one")
  await model.settled()
  try model.go(#require(url("wicket://?input=hello")), from: "extension:two")
  #expect(model.command == nil && model.input == "hello")
  // `agent` leaves an open command for an empty conversation holding the unsent text.
  model.go(Address(id: "extension:one"))
  await model.settled()
  model.go(Address(extensionName: "agent", input: "Why?"), from: "extension:one")
  #expect(model.input == "Why?" && model.agent.active && !model.agent.busy && model.command == nil)
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
  #expect(ask["row"]["actions"].array.first?["type"].string == "send")
  #expect(ask["row"]["actions"].array.first?["text"].string == "ship")
}

@Test func reservedFolderNamesAreDiscoveryProblems() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["settings", "Agent", "clipboard", "fine"] {
    _ = try extensionFolder(root, name: name, fields: ["command": ["/usr/bin/true"]])
  }
  let (commands, problems) = ExtensionHost.discover(root.appending(path: "extensions"))
  #expect(Set(commands.keys) == ["extension:fine"])
  #expect(problems["extension:settings"]?.contains("reserved") == true)
  #expect(problems["extension:Agent"]?.contains("reserved") == true)
  #expect(problems["extension:clipboard"]?.contains("reserved") == true)
}

/// `chosen` is the user activating something: the command and fallback rows, a run action (JSON or the
/// host's, a manifest item included). Never typing, refreshes, links, details or error rows.
@MainActor @Test func chosenMeansTheUserActivatedIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Every request is logged; a page with run actions of each shape, or a failure for "fail".
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    if r['input'].startswith('fail'): sys.exit(1)
    run=lambda i,a: {'id':i,'title':i,'actions':[dict({'type':'run'},**a)]}
    print(json.dumps({'body':'page','items':[run('with',{'arguments':{'a':'1'}}),run('empty',{'arguments':{}}),
      run('none',{}),{'id':'link','title':'link','actions':[{'type':'open','url':'wicket://ship?input=o'}]}]}))
    """
  let folder = try extensionFolder(
    root, name: "ship",
    fields: [
      "name": "Ship", "command": ["/usr/bin/python3", "ship.py"], "match": "^(page|fail)", "fallback": true,
      "items": [
        ["id": "prod", "title": "Deploy prod", "actions": [["type": "run", "arguments": ["env": "prod"]]]]
      ],
    ])
  try Data(script.utf8).write(to: folder.appending(path: "ship.py"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  func requests() throws -> [ProviderRequest] {
    let log = (try? String(contentsOf: folder.appending(path: "log.jsonl"), encoding: .utf8)) ?? ""
    return try log.split(separator: "\n").map {
      try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8))
    }
  }
  /// Activates a row and returns the one request that followed.
  func activate(_ action: RowAction, from result: Result? = nil) async throws -> ProviderRequest {
    let before = try requests().count
    model.activate(action, from: result)
    await model.settled()
    let after = try requests()
    #expect(after.count == before + 1)
    return try #require(after.last)
  }
  func atRoot(_ input: String, _ pick: (Result) -> Bool) async throws -> Result {
    _ = model.escape()
    model.input = input
    await model.settled()
    return try #require(model.results.first { pick($0) }, Comment(rawValue: input))
  }
  func item(_ id: String) throws -> Result { try #require(model.results.first { $0.row.id == id }) }

  // The command row, the fallback row and a manifest item are chosen.
  var row = try await atRoot("ship") { $0.row.id == "command" }
  #expect(try await activate(row.row.actions[0], from: row).chosen)
  row = try await atRoot("an unrelated sentence") { $0.row.id == "fallback" }
  #expect(try await activate(row.row.actions[0], from: row).chosen)
  row = try await atRoot("deploy prod") { $0.row.id == "item:prod" }
  let fromItem = try await activate(row.row.actions[0], from: row)
  #expect(fromItem.chosen && fromItem.arguments == ["env": "prod"])
  // A run action with arguments, with `{}` and without any: chosen, with exactly those arguments.
  let shapes: [(String, [String: String])] = [("with", ["a": "1"]), ("empty", [:]), ("none", [:])]
  for (id, arguments) in shapes {
    let request = try await activate(try item(id).row.actions[0], from: try item(id))
    #expect(request.chosen && request.arguments == arguments, Comment(rawValue: id))
  }
  // Typing reruns and a catalog refresh are not.
  model.go(Address(id: "extension:ship", arguments: ["a": "1"]), chosen: true)
  await model.settled()
  model.input = "p"
  await model.settled()
  #expect(try requests().last.map { !$0.chosen && $0.arguments == ["a": "1"] && $0.input == "p" } == true)
  model.sourcesChanged(["extension:ship"])
  await model.settled()
  #expect(try requests().last?.chosen == false)
  // Links: a JSON open of a wicket URL, an outside URL, an agent item. Never chosen, never arguments.
  var request = try await activate(try item("link").row.actions[0], from: try item("link"))
  #expect(!request.chosen && request.arguments.isEmpty && request.input == "o")
  request = try await activate(.run(try #require(url("wicket://ship?input=prod"))))
  #expect(!request.chosen && request.input == "prod")
  let agentItem = try #require(
    ProviderView(reply: #"<item title="Ship" open="wicket://ship?input=a"/>"#).items.first)
  request = try await activate(agentItem.actions[0], from: Result(provider: "answer", row: agentItem))
  #expect(!request.chosen && request.input == "a")
  // The host's Show details and error rows only show what a pattern produced.
  row = try await atRoot("page one") { $0.row.id == "detail" }
  request = try await activate(row.row.actions[0], from: row)
  #expect(!request.chosen && request.input == "page one")
  row = try await atRoot("fail now") { $0.row.id == "error" }
  request = try await activate(row.row.actions[0], from: row)
  #expect(!request.chosen && request.input == "fail now")
  await model.finish()
}
