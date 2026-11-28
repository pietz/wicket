import Foundation
import Testing

@testable import WicketApp

private func action(_ json: String) throws -> RowAction {
  try JSONDecoder().decode(RowAction.self, from: Data(json.utf8))
}

private func url(_ text: String) -> Address? { Address(url: URL(string: text)!) }

/// The address a URL spells: a link, never with fields.
private func link(_ name: String, _ input: String? = nil) -> Address {
  Address(extensionName: name, input: input, link: true)
}

@Test func anAddressDecodesFromJSONAndFromAURL() throws {
  #expect(
    try action(#"{"type":"run","extension":"weather","input":"berlin","fields":{"view":"hourly"}}"#)
      == .run(Address(extensionName: "weather", input: "berlin", fields: ["view": "hourly"])))
  // Omitted means this one, as now; an empty object is no fields, said explicitly.
  #expect(try action(#"{"type":"run","fields":{"id":"42"}}"#) == .run(Address(fields: ["id": "42"])))
  #expect(try action(#"{"type":"run","fields":{}}"#) == .run(Address(fields: [:])))
  #expect(try action(#"{"type":"run"}"#) == .run(Address()))
  #expect(try action(#"{"type":"agent","text":"Why?"}"#) == .agent("Why?"))
  let sent = Address(
    extensionName: "weather", input: "berlin", fields: ["view": "hourly", "city": "berlin"])
  #expect(
    try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(RowAction.run(sent))) == .run(sent))
  #expect(throws: (any Error).self) { try action(#"{"type":"run","fields":"hourly"}"#) }
  #expect(throws: (any Error).self) { try action(#"{"type":"run","fields":{"n":1}}"#) }
  // The positional array is gone: it is a decoding error with its path, like any malformed view.
  do {
    _ = try JSONDecoder().decode(
      ProviderView.self,
      from: Data(
        #"{"items":[{"id":"a","title":"A","actions":[{"type":"run","fields":["hourly"]}]}]}"#.utf8))
    Issue.record("An array of fields decoded")
  } catch let DecodingError.typeMismatch(_, context) {
    #expect(context.codingPath.map(\.stringValue) == ["items", "Index 0", "actions", "Index 0", "fields"])
  }
  // A full request with positional fields fails at `fields`, not at some missing field.
  func request(_ fields: String) throws -> ProviderRequest {
    let json =
      #"{"input":"","submitted":false,"locale":{"decimal":".","grouping":","},"settings":{},"fields":"#
    return try JSONDecoder().decode(ProviderRequest.self, from: Data((json + fields + "}").utf8))
  }
  #expect(try request(#"{"n":"1"}"#).fields == ["n": "1"])
  do {
    _ = try request(#"["a"]"#)
    Issue.record("An array of request fields decoded")
  } catch let DecodingError.typeMismatch(_, context) {
    #expect(context.codingPath.map(\.stringValue) == ["fields"])
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
    #"{"type":"run","fields":{"id":"42"},"title":"Delete"}"#,
    #"{"type":"agent","text":"Why?","title":"Ask why"}"#,
  ]
  for json in titled {
    let decoded = try action(json)
    #expect(decoded.title != nil && decoded.label == decoded.title)
    #expect(try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(decoded)) == decoded)
  }
  #expect(try action(#"{"type":"open","url":"wicket://weather","title":"Weather"}"#).label == "Weather")
  // Without a title each kind keeps its label; a run is Run for this command and Open elsewhere.
  #expect(try action(#"{"type":"run","fields":{"id":"42"}}"#).label == "Run")
  #expect(try action(#"{"type":"run","extension":"weather"}"#).label == "Open")
  #expect(try action(#"{"type":"open","url":"wicket://?input=x"}"#).label == "Open")
  #expect(try action(#"{"type":"agent","text":"Why?"}"#).label == "Ask agent…")
  #expect(try action(#"{"type":"copy","text":"42"}"#).label == "Copy")
  // A title is encoded only when there is one.
  #expect(
    String(decoding: try JSONEncoder().encode(RowAction.copy("x")), as: UTF8.self).contains("title") == false)
}

@Test func outsidersNameATargetAndAnInputButNeverArguments() throws {
  // A URL has no way to carry fields or an action: a query item of that name is ignored.
  let outside = url("wicket://deploy?input=prod&fields=%7B%22a%22%3A%22b%22%7D&extension=other&action=deploy")
  #expect(outside == link("deploy", "prod") && outside?.fields == nil)
  // The same goes for what an agent writes: its rows and the links in its text.
  let page = Page(
    body: #"<row title="Open" open="wicket://deploy?input=prod&fields=%5B%22delete%22%5D"/>"#
      + #"<row title="Root" open="wicket://?input=hello"/><row title="Why" ask="Why?"/>"#, runs: false)
  #expect(
    page.targets.map(\.actions) == [
      [.run(link("deploy", "prod"))],
      [.run(link("", "hello"))],
      [.agent("Why?")],
    ])
  #expect(page.targets.allSatisfy { $0.actions.count == 1 })
  #expect(AnswerLink.allowed(URL(string: "wicket://deploy?input=x")))
  // The wire has no spelling that gives a URL fields or an action, whichever action carries it.
  #expect(
    try action(#"{"type":"open","url":"wicket://deploy?input=x&fields=%5B%22a%22%5D"}"#)
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
  let model = LauncherModel.testing(in: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  let surface = RecordingSurface()
  model.navigator.surface = surface
  await model.extensions.reload()

  /// Selects the row and presses Return, which is the only way in.
  func press(_ input: String, _ pick: (Result) -> Bool) async throws {
    _ = model.navigator.escape()
    model.navigator.input = input
    await model.navigator.settled()
    let row = try #require(model.navigator.results.first { pick($0) }, Comment(rawValue: input))
    #expect(row.row.actions.count == 1)
    model.navigator.select(row.id)
    #expect(model.activateReturn())
    await model.navigator.settled()
  }

  // Name match: the command row enters with empty input.
  try await press("sh") { $0.row.id == "command" }
  #expect(model.navigator.command?.id == "extension:ship" && model.navigator.input == "")
  // Fallback: enters with the root query kept.
  try await press("an unrelated sentence") { $0.row.id == "fallback" }
  #expect(model.navigator.command?.id == "extension:ship" && model.navigator.input == "an unrelated sentence")
  // A pattern result with a body: enters with the query kept and shows the body.
  try await press("page one") { $0.row.id == "detail" }
  #expect(
    model.navigator.command?.id == "extension:page" && model.navigator.input == "page one"
      && model.navigator.body == "## Details")
  // A failed pattern: the error row enters the command with the query kept, which runs it again and
  // shows the failure with its report, where the header offers Ask agent.
  try await press("broken now") { $0.row.id == "error" }
  #expect(model.navigator.command?.id == "extension:broken" && model.navigator.input == "broken now")
  let problem = try #require(model.navigator.command?.problem)
  #expect(problem.contains("REPAIR") && problem.contains("Command:") && problem.contains("broken now"))
  // An invalid manifest: the repair row drafts the brief in an empty conversation and sends nothing.
  try await press("zzz") { $0.row.id == "discovery-error" }
  #expect(model.navigator.input.contains("Invalid wicket.json") && model.navigator.command == nil)
  #expect(model.agent.active && !model.agent.busy && model.agent.question.isEmpty)
  // Settings.
  try await press("settings") { $0.provider == "settings" }
  #expect(surface.count(.settings) == 1)
  // Ask agent sends the question.
  try await press("Where is the moon?") { $0.provider == "agent" }
  #expect(await eventually { fake.running })
  #expect(model.agent.question == "Where is the moon?")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  // Ending the conversation goes back to the root.
  #expect(model.navigator.escape())
  await model.navigator.settled()

  // Nothing the root list shows is without an action.
  model.navigator.input = "ship"
  await model.navigator.settled()
  #expect(!model.navigator.results.isEmpty && model.navigator.results.allSatisfy { !$0.row.actions.isEmpty })
  await model.finish()
}

@MainActor @Test func anAddressOpensAnotherExtensionTheRootOrTheAgentAndKeepsTypedInputInTheSameCommand()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let echo =
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':'/'.join(sorted(v for k,v in r['fields'].items() if k!='query'))+':'+r['input']}))"
  for name in ["one", "two"] {
    let folder = try extensionFolder(root, name: name, fields: ["command": ["/usr/bin/python3", "echo.py"]])
    try Data(echo.utf8).write(to: folder.appending(path: "echo.py"))
  }
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  // An extension's own row may name another extension with fields.
  model.navigator.go(
    Address(extensionName: "two", input: "x", fields: ["p": "a", "q": "b"]), from: "extension:one")
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:two" && model.navigator.body == "a/b:x")
  // Without a target it is this one, and without an input the typed one stays.
  model.navigator.go(Address(fields: ["p": "c"]), from: "extension:two")
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:two" && model.navigator.body == "b/c:x")
  // Entering another extension without an input starts empty.
  model.navigator.go(Address(id: "extension:one"))
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:one" && model.navigator.body == ":")
  // An unknown extension changes nothing and says so.
  model.navigator.go(Address(extensionName: "nothing", input: "x"))
  #expect(
    model.navigator.command?.id == "extension:one"
      && model.navigator.actionProblem?.contains("nothing") == true)
  // No target is a root query.
  model.navigator.go(Address(input: "calc"))
  #expect(model.navigator.command == nil && model.navigator.input == "calc")
  // A root URL stays the root even from an extension's own row, where an omitted target is that one.
  try model.navigator.go(#require(url("wicket://two?input=y")), from: "extension:one")
  await model.navigator.settled()
  try model.navigator.go(#require(url("wicket://?input=hello")), from: "extension:two")
  #expect(model.navigator.command == nil && model.navigator.input == "hello")
  // `agent` leaves an open command for an empty conversation holding the unsent text.
  model.navigator.go(Address(id: "extension:one"))
  await model.navigator.settled()
  model.navigator.go(Address(extensionName: "agent", input: "Why?"), from: "extension:one")
  #expect(
    model.navigator.input == "Why?" && model.agent.active && !model.agent.busy
      && model.navigator.command == nil)
  await model.finish()
}

@MainActor @Test(arguments: [("wicket://agent", ""), ("wicket://agent?input=Why%3F", "Why?")])
func anAgentLinkDraftsOnlyItsInput(link: String, expected: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  model.navigator.input = "Unrelated search"
  try model.navigator.go(#require(url(link)))
  #expect(model.navigator.input == expected)
  #expect(model.agent.active && !model.agent.busy && model.agent.question.isEmpty)
  await model.finish()
}

@Test func plainStdoutIsAMarkdownBodyAndBrokenJSONStaysAnError() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  func run(_ script: String) async throws -> ProviderView {
    let folder = try extensionFolder(root, name: "plain", script: script)
    return try await ExtensionRunner(dataDirectory: root).run(command(folder), request: .init(input: ""))
  }
  let markdown = try await run("printf '## Done\\n<row label=\"Total\" value=\"42\"/>\\n'")
  #expect(markdown.body == "## Done\n<row label=\"Total\" value=\"42\"/>" && markdown.items.isEmpty)
  // Its row tags stay where they stand; the page reads them as an extension's own.
  let tagged = try await run(
    "printf 'See <row title=\"Docs\" open=\"https://example.com\"/>'")
  #expect(tagged.body == #"See <row title="Docs" open="https://example.com"/>"# && tagged.items.isEmpty)
  #expect(Page(body: tagged.body ?? "", runs: true).targets.map(\.title) == ["Docs"])
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
  #expect(!rows.contains { $0["provider"].string == "agent" })
  let sentence = try await cli(root, ["--query", "why did it fail"])
  let ask = try #require(sentence.1["items"].array.first { $0["provider"].string == "agent" })
  #expect(ask["row"]["actions"].array.first?["type"].string == "send")
  #expect(ask["row"]["actions"].array.first?["text"].string == "why did it fail")
}

/// A misspelled manifest key is a repair row that names it and the valid keys, never silently ignored.
@Test func unknownManifestKeysAreDiscoveryProblems() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "typo", fields: ["keywords": ["t"]])
  _ = try extensionFolder(root, name: "fine", fields: ["match": "^x", "submit": true, "description": "D"])
  let (commands, problems, _) = ExtensionHost.discover(root.appending(path: "extensions"), bundled: nil)
  #expect(Set(commands.keys) == ["extension:fine"])
  let problem = try #require(problems["extension:typo"]?.detail)
  #expect(problem.contains("Unknown key `keywords`"))
  #expect(problem.contains("valid keys: name, description, keyword, command"))
}

@Test func reservedFolderNamesAreDiscoveryProblems() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["settings", "Agent", "clipboard", "fine"] {
    _ = try extensionFolder(root, name: name, fields: ["command": ["/usr/bin/true"]])
  }
  let (commands, problems, _) = ExtensionHost.discover(root.appending(path: "extensions"), bundled: nil)
  #expect(Set(commands.keys) == ["extension:fine"])
  #expect(problems["extension:settings"]?.detail.contains("reserved") == true)
  #expect(problems["extension:Agent"]?.detail.contains("reserved") == true)
  #expect(problems["extension:clipboard"]?.detail.contains("reserved") == true)
}

/// `submitted` is the user activating something: the command and fallback rows, a run action (JSON or the
/// host's, a manifest item included). Never typing, refreshes, links, details or error rows.
@MainActor @Test func submittedMeansTheUserActivatedIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Every request is logged; a page with run actions of each shape, or a failure for "fail".
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    if r['input'].startswith('fail'): sys.exit(1)
    run=lambda i,a: {'id':i,'title':i,'actions':[dict({'type':'run'},**a)]}
    print(json.dumps({'body':'page','items':[run('with',{'fields':{'a':'1'}}),run('empty',{'fields':{}}),
      run('none',{}),{'id':'link','title':'link','actions':[{'type':'open','url':'wicket://ship?input=o'}]}]}))
    """
  let folder = try extensionFolder(
    root, name: "ship",
    fields: [
      "name": "Ship", "command": ["/usr/bin/python3", "ship.py"], "match": "^(page|fail)", "fallback": true,
      "items": [
        ["id": "prod", "title": "Deploy prod", "actions": [["type": "run", "fields": ["env": "prod"]]]]
      ],
    ])
  try Data(script.utf8).write(to: folder.appending(path: "ship.py"))
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  func requests() throws -> [ProviderRequest] { try WicketTests.requests(in: folder) }
  /// Activates a row and returns the one request that followed.
  func activate(_ action: RowAction, from result: Result? = nil) async throws -> ProviderRequest {
    let before = try requests().count
    model.navigator.activate(action, from: result)
    await model.navigator.settled()
    let after = try requests()
    #expect(after.count == before + 1)
    return try #require(after.last)
  }
  func atRoot(_ input: String, _ pick: (Result) -> Bool) async throws -> Result {
    _ = model.navigator.escape()
    model.navigator.input = input
    await model.navigator.settled()
    return try #require(model.navigator.results.first { pick($0) }, Comment(rawValue: input))
  }
  func item(_ id: String) throws -> Result { try #require(model.navigator.results.first { $0.row.id == id }) }

  // The command row, the fallback row and a manifest item are submitted.
  var row = try await atRoot("ship") { $0.row.id == "command" }
  #expect(try await activate(row.row.actions[0], from: row).submitted)
  row = try await atRoot("an unrelated sentence") { $0.row.id == "fallback" }
  #expect(try await activate(row.row.actions[0], from: row).submitted)
  row = try await atRoot("deploy prod") { $0.row.id == "item:prod" }
  let fromItem = try await activate(row.row.actions[0], from: row)
  #expect(fromItem.submitted && fromItem.fields == ["env": "prod"])
  // A run action with fields, with `{}` and without any: submitted, preserving fields from earlier actions.
  let shapes: [(String, [String: String])] = [
    ("with", ["a": "1", "env": "prod"]), ("empty", ["a": "1", "env": "prod"]),
    ("none", ["a": "1", "env": "prod"]),
  ]
  for (id, fields) in shapes {
    let request = try await activate(try item(id).row.actions[0], from: try item(id))
    #expect(request.submitted && request.fields == fields, Comment(rawValue: id))
  }
  // Typing reruns and a catalog refresh are not.
  model.navigator.go(Address(id: "extension:ship", fields: ["a": "1"], action: "preview"), submitted: true)
  await model.navigator.settled()
  #expect(try requests().last?.action == "preview")
  model.navigator.input = "p"
  await model.navigator.settled()
  #expect(
    try requests().last.map {
      !$0.submitted && $0.action == nil && $0.fields == ["a": "1", "env": "prod", "query": "p"]
        && $0.input == "p"
    }
      == true)
  model.navigator.sourcesChanged(["extension:ship"])
  await model.navigator.settled()
  #expect(try requests().last?.submitted == false)
  // Links: a JSON open of a wicket URL, an outside URL, an agent item. Never submitted, no explicit fields or action.
  var request = try await activate(try item("link").row.actions[0], from: try item("link"))
  #expect(!request.submitted && request.fields == ["query": "o"] && request.input == "o")
  request = try await activate(.run(try #require(url("wicket://ship?input=prod"))))
  #expect(!request.submitted && request.input == "prod")
  let agentItem = try #require(
    Page(body: #"<row title="Ship" open="wicket://ship?input=a"/>"#, runs: false).targets.first)
  request = try await activate(agentItem.actions[0], from: Result(provider: "answer", row: agentItem))
  #expect(!request.submitted && request.input == "a")
  request = try await activate(.run(try #require(url("wicket://ship"))))
  #expect(!request.submitted && request.input.isEmpty && request.fields.isEmpty)
  // The host's Show details and error rows only show what a pattern produced.
  row = try await atRoot("page one") { $0.row.id == "detail" }
  request = try await activate(row.row.actions[0], from: row)
  #expect(!request.submitted && request.input == "page one")
  row = try await atRoot("fail now") { $0.row.id == "error" }
  request = try await activate(row.row.actions[0], from: row)
  #expect(!request.submitted && request.input == "fail now")
  await model.finish()
}

@MainActor @Test func aLinkThatLaunchesWicketWaitsForTheFirstExtensionScan() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "first", script: answering("First"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.navigator.open(try #require(Address(url: URL(string: "wicket://first")!)))
  model.extensions.start()
  #expect(await eventually { model.navigator.command?.id == "extension:first" })
  #expect(model.navigator.actionProblem == nil)
  await model.finish()
}

@MainActor @Test func everyAddressResolvesThroughOneDirectory() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "weather")
  let runs = AgentHistory(url: root.appending(path: "agent-history.json"))
  runs.save(.init(id: "r", agent: .claude, session: "s", used: Date(), source: nil, turns: []))
  let clipboard = ClipboardHistory(
    url: root.appending(path: "clipboard-history.json"), pasteboard: FakePasteboard(), interval: nil)
  let model = LauncherModel(
    clipboard: clipboard, agentHistory: runs, history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root, bundled: nil)
  await model.extensions.reload()
  let directory = CommandDirectory(
    extensions: model.extensions, hosts: [clipboard, runs], store: model.store)
  for (target, expected) in [
    (nil, "root"), ("agent", "agent"), ("settings", "settings"), ("history", "history"),
    ("clipboard", "clipboard"), ("extension:weather", "extension:weather"), ("extension:gone", "none"),
  ] as [(String?, String)] {
    let resolved =
      switch directory.destination(target) {
      case .root: "root"
      case .agent: "agent"
      case .settings: "settings"
      case .command(let behavior): behavior.id
      case nil: "none"
      }
    #expect(resolved == expected)
  }
  #expect(
    directory.name(of: "history") == "Agent History" && directory.name(of: "extension:weather") == "weather")
  // Agent History opens whatever is on; Clipboard and extensions only while on.
  var configuration = Configuration()
  #expect(
    directory.isAvailable("history", in: configuration)
      && !directory.isAvailable("clipboard", in: configuration))
  #expect(directory.isAvailable("extension:weather", in: configuration))
  #expect(directory.rootRows(configuration).map(\.provider) == ["settings", "history"])
  configuration.providers = [.init("clipboard"), .init("extension:weather", enabled: false)]
  #expect(directory.isAvailable("clipboard", in: configuration))
  #expect(!directory.isAvailable("extension:weather", in: configuration))
  #expect(directory.rootRows(configuration).map(\.provider) == ["settings", "history", "clipboard"])
  // Only a submitted Reopen of a run that exists opens a conversation.
  func restores(_ id: String, _ open: String, _ cause: CommandScreen.Cause = .submission) -> String? {
    let request = CommandScreenRequest(input: "", fields: ["id": open], action: "open", cause: cause)
    guard case .immediate(.restore(let run)) = directory.behavior(of: id)?.work(for: request) else {
      return nil
    }
    return run.id
  }
  #expect(restores("history", "r") == "r" && restores("history", "r", .address) == nil)
  #expect(restores("history", "gone") == nil && restores("clipboard", "r") == nil)
  #expect(directory.rootRows(configuration).allSatisfy(CommandDirectory.isRootRow))
  #expect(
    !CommandDirectory.isRootRow(
      Result(provider: "extension:weather", row: Row(id: "open", title: "W", actions: []))))
  await model.finish()
}

@MainActor @Test func aRootWithoutTheHostStoresStillListsTheirRows() async throws {
  // Headless has no history store, and its list matches the panel's.
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.navigator.input = "history"
  await model.navigator.settled()
  #expect(model.navigator.results.first?.id == "history:open")
  model.navigator.go(Address(extensionName: "history"))
  #expect(model.navigator.command == nil && model.navigator.actionProblem == "No extension named history")
  await model.finish()
}
