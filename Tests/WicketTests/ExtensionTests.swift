import Darwin
import Foundation
import Testing

@testable import WicketApp

func extensionFolder(
  _ root: URL, name: String = "test", script: String = "echo '{\"items\":[]}'",
  fields: [String: Any] = [:]
) throws -> URL {
  let folder = root.appending(path: "extensions/" + name)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var manifest: [String: Any] = [
    "contract": 2, "name": name, "keyword": name, "command": ["/bin/sh", "main.sh"],
  ]
  manifest["fields"] = [["name": "query", "type": "text", "description": "Search"]]
  manifest.merge(fields) { _, value in value }
  try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(
    to: folder.appending(path: "wicket.json"))
  try Data(script.utf8).write(to: folder.appending(path: "main.sh"))
  return folder
}
func answering(_ title: String) -> String {
  let data = try! JSONEncoder().encode(
    ProviderView(items: [Row(id: "one", title: title, actions: [.copy(title)])]))
  return "cat >/dev/null\nprintf '%s' '" + String(decoding: data, as: UTF8.self) + "'"
}

@MainActor @Test func headlessViewLinksRoundTripAsUnsubmittedAddresses() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try extensionFolder(
    root, name: "links",
    script:
      #"echo '{"items":[],"actions":[{"type":"open","url":"wicket://target?input=a%2Bb%20%26%20c&action=ignored"}],"body":"Links"}'"#
  )
  let target = try extensionFolder(
    root, name: "target", script: #"cat >request.json; echo '{"body":"Target"}'"#)
  let (status, json) = try await cli(root, ["--extension", "links"])
  #expect(status == 0)
  #expect(json["actions"].array.first?["type"] == .string("open"))
  let view = try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(json))
  let action = try #require(view.actions.first)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.activate(action, from: nil)
  await model.navigator.settled()
  let request = try JSONDecoder().decode(
    ProviderRequest.self, from: Data(contentsOf: target.appending(path: "request.json")))
  #expect(request.input == "a+b & c" && !request.submitted && request.action == nil)
  await model.finish()
}

@Test func completeExtensionWireContract() throws {
  #expect(
    Result(provider: "extension:a", row: Row(id: "b:c", title: "A", actions: [])).id
      != Result(provider: "extension:a:b", row: Row(id: "c", title: "B", actions: [])).id)
  let view = ProviderView(
    body: "<row label=\"Total\" value=\"42\"/>", items: [Row(id: "more", title: "More", actions: [])],
    actions: [
      .open(URL(string: "https://example.com")!), .copy("42"), .paste("42"),
      .run(Address(fields: ["id": "42"]), title: "Refresh"), .agent("Explain 42"),
    ])
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
  for json in [
    #"{"items":[{"id":"x","title":"X","actions":[]},{"id":"x","title":"X","actions":[]}]}"#,
    #"{}"#, #"{"type":"detail","metadata":[]}"#, #"{"actions":[]}"#,
    #"{"items":[{"id":"","title":"X","actions":[]}]}"#,
    #"{"items":[{"id":"x","title":"X","actions":[{"type":"open"}]}]}"#,
  ] {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8)) }
  }
  for manifest in [
    #"{"contract":2,"name":"Bad","command":[]}"#,
    // Neither a command nor items; a pattern or fallback without a program; the view's item rule.
    #"{"name":"Bad"}"#, #"{"name":"Bad","items":[],"match":"x"}"#,
    #"{"name":"Bad","items":[],"fallback":true}"#,
    #"{"name":"Bad","items":[],"version":"1.2"}"#,
    #"{"name":"Bad","items":[],"version":"01.2.0"}"#,
    #"{"name":"Bad","items":[],"version":"1.2.0-rc.01"}"#,
    #"{"name":"Bad","items":[{"id":"a","title":"A","actions":[]},{"id":"a","title":"B","actions":[]}]}"#,
    #"{"name":"Bad","items":[{"id":"","title":"A","actions":[]}]}"#,
  ] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ExtensionManifest.self, from: Data(manifest.utf8))
    }
  }
  let itemsOnly = try JSONDecoder().decode(
    ExtensionManifest.self,
    from: Data(#"{"name":"Links","items":[{"id":"a","title":"A","actions":[]}]}"#.utf8))
  #expect(itemsOnly.command == nil && itemsOnly.items?.map(\.id) == ["a"])
  let both = try JSONDecoder().decode(
    ExtensionManifest.self,
    from: Data(#"{"contract":2,"name":"Both","command":["echo"],"match":"x","items":[]}"#.utf8))
  #expect(both.command == ["echo"] && both.items == [])
}

@Test func extensionVersionsFollowSemanticVersionPrecedence() throws {
  let decoder = JSONDecoder()
  func version(_ text: String) throws -> ExtensionManifest.Version {
    try decoder.decode(ExtensionManifest.Version.self, from: JSONEncoder().encode(text))
  }
  let order = try ["1.0.0-rc.2", "1.0.0-rc.10", "1.0.0-rc.z", "1.0.0", "1.0.10"].map(version)
  for (lower, higher) in zip(order, order.dropFirst()) {
    #expect(lower.precedes(higher))
    #expect(!higher.precedes(lower))
  }
  let release = try version("1.0.0")
  let build = try version("1.0.0+build.01")
  #expect(release != build && !release.precedes(build) && !build.precedes(release))
}

@Test func invalidExtensionPatternsFailAtTheMatchKey() throws {
  let limit = String(repeating: "é", count: 256)
  let json = #"{"contract":2,"name":"Pattern","command":["echo"],"match":"\#(limit)"}"#
  _ = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
  for pattern in ["[", limit + "x"] {
    let invalid = #"{"contract":2,"name":"Pattern","command":["echo"],"match":"\#(pattern)"}"#
    do {
      _ = try JSONDecoder().decode(ExtensionManifest.self, from: Data(invalid.utf8))
      Issue.record("An invalid pattern decoded")
    } catch let DecodingError.dataCorrupted(context) {
      #expect(context.codingPath.map(\.stringValue) == ["match"])
    }
  }
}

@Test func extensionPatternsMatchRepeatedlyAndRespectTheInputLimit() throws {
  let decoder = JSONDecoder()
  let data = Data(#"{"contract":2,"name":"Pattern","command":["echo"],"match":"^🌍"}"#.utf8)
  let manifest = try decoder.decode(ExtensionManifest.self, from: data)
  let atLimit = String(repeating: "🌍", count: 1024)
  #expect(manifest.matches(atLimit))
  #expect(!manifest.matches(atLimit + "!"))
  #expect(!manifest.matches("hello🌍"))
  #expect(manifest.matches("🌍hello"))

  let differentPattern = try decoder.decode(
    ExtensionManifest.self,
    from: Data(#"{"contract":2,"name":"Pattern","command":["echo"],"match":"^x"}"#.utf8))
  #expect(differentPattern != manifest)
  let withoutPattern = try decoder.decode(
    ExtensionManifest.self, from: Data(#"{"contract":2,"name":"Pattern","command":["echo"]}"#.utf8))
  #expect(!withoutPattern.matches("🌍hello"))
}

@MainActor @Test func anExtensionWithItemsAndNoCommandIsAnsweredByWicketAndFoundAtTheRoot() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let items: [[String: Any]] = [
    ["id": "b", "title": "Beta Docs", "actions": [["type": "run", "input": "beta"]]],
    ["id": "a", "title": "Alpha", "keywords": ["docs"], "actions": []],
    ["id": "c", "title": "Gamma", "actions": []],
  ]
  let folder = try extensionFolder(
    root, name: "links", fields: ["name": "Links", "icon": "bookmark", "items": items])
  // No program: the manifest alone is the extension.
  var manifest =
    try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "wicket.json")))
    as! [String: Any]
  manifest["command"] = nil
  try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  try FileManager.default.removeItem(at: folder.appending(path: "main.sh"))
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:links")] }
  await model.extensions.reload()
  model.navigator.input = ""
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Links"])
  model.navigator.input = "docs"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Alpha", "Beta Docs"])
  // An item's run action without `extension` means its own extension.
  let beta = try #require(model.navigator.results.first { $0.row.title == "Beta Docs" })
  model.navigator.activate(beta.row.actions[0], from: beta)
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:links" && model.navigator.input == "beta")
  #expect(model.navigator.results.map(\.row.title) == ["Beta Docs"])
  model.navigator.input = ""
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Beta Docs", "Alpha", "Gamma"])
  // Inside its command, the extension's icon remains a presentation fallback.
  #expect(model.navigator.results.allSatisfy { $0.row.icon == nil && $0.row.subtitle == nil })
  model.navigator.input = "docs"
  await model.navigator.settled()
  // Filtered and ordered like any command's items: an exact keyword before the manifest's order.
  #expect(model.navigator.results.map(\.row.title) == ["Alpha", "Beta Docs"])
  #expect(model.navigator.escape())
  model.store.update { $0.providers = [.init("extension:links", enabled: false)] }
  model.navigator.input = "docs"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["agent"])
  await model.finish()
}

@Test func oneViewDecodesItemsOnlyBodyOnlyAndBoth() throws {
  func decode(_ json: String) throws -> ProviderView {
    try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  }
  let item = Row(id: "a", title: "A", actions: [.copy("a")])
  let itemJSON = #"{"id":"a","title":"A","actions":[{"type":"copy","text":"a"}]}"#
  #expect(try decode(#"{"items":[\#(itemJSON)]}"#) == ProviderView(items: [item]))
  #expect(try decode(#"{"items":[]}"#) == ProviderView())
  #expect(
    try decode(#"{"body":"Hi","actions":[{"type":"copy","text":"a"}]}"#)
      == ProviderView(body: "Hi", actions: [.copy("a")]))
  #expect(
    try decode(#"{"body":"Hi","items":[\#(itemJSON)]}"#) == ProviderView(body: "Hi", items: [item]))
  // A rows-only response has no supported content.
  #expect(try decode(#"{"type":"detail","body":"hi"}"#) == ProviderView(body: "hi"))
  #expect(throws: ProviderView.Empty.self) { try decode(#"{"rows":[\#(itemJSON)]}"#) }
  #expect(
    try decode(#"{"body":"hi","metadata":[{"label":"a","value":"b"}]}"#)
      == ProviderView(body: "hi"))
}

@MainActor @Test func aBodyWithItemsSelectsItemsAndReturnRunsTheSelectedOne() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(
    body: "## Berlin",
    items: [
      Row(id: "a", title: "One", actions: [.copy("one")]),
      Row(id: "b", title: "Two", actions: [.copy("two")]),
    ],
    actions: [.copy("view")])
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(root, script: "cat >/dev/null\nprintf '%s' '\(json)'")
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.body == "## Berlin" && model.navigator.results.map(\.row.id) == ["a", "b"])
  #expect(model.navigator.viewActions == [.copy("view")])
  // A page starts with nothing selected: Return runs the view's actions until an arrow key enters the items.
  #expect(model.navigator.selection == nil && model.navigator.selected?.row.actions == [.copy("view")])
  model.navigator.move(1)
  #expect(
    model.navigator.selected?.row.id == "a" && model.navigator.selected?.row.actions.first == .copy("one"))
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.id == "b")
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.id == "b")
  model.navigator.move(-1)
  model.navigator.move(-1)
  #expect(model.navigator.selection == nil && model.navigator.selected?.row.actions == [.copy("view")])
  await model.finish()
}

@MainActor @Test func aPatternResultWithABodyOnlyOffersToEnterTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(body: "## Berlin", items: [Row(id: "a", title: "Inner", actions: [])])
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(
    root, script: "cat >/dev/null\nprintf '%s' '\(json)'", fields: ["match": "^weather"])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "weather berlin"
  await model.navigator.settled()
  #expect(model.navigator.results.first { $0.provider == "extension:test" }?.row.id == "detail")
  #expect(!model.navigator.results.contains { $0.row.title == "Inner" })
  await model.finish()
}

func command(_ folder: URL) throws -> ExtensionCommand {
  try #require(
    ExtensionHost.discover(folder.deletingLastPathComponent(), bundled: nil).0[
      "extension:" + folder.lastPathComponent])
}

@Test func requestIsJSONAndTheProgramRunsFromItsOwnFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, script: answering("Hello"))
  #expect(
    try await ExtensionRunner(dataDirectory: root).run(command(ext), request: .init(input: "hello"))
      == .init(items: [Row(id: "one", title: "Hello", actions: [.copy("Hello")])]))
  try Data(
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':r['input'],'items':[{'id':'args','title':'/'.join(k+'='+v for k,v in sorted(r['fields'].items())),'actions':[]}]}))"
      .utf8
  ).write(to: ext.appending(path: "echo.py"))
  let data = try JSONSerialization.data(withJSONObject: [
    "contract": 2, "name": "Echo", "command": ["/usr/bin/python3", "echo.py"],
  ])
  try data.write(to: ext.appending(path: "wicket.json"))
  #expect(
    try await ExtensionRunner(dataDirectory: root).run(
      command(ext), request: .init(input: "héllo \"世界\"", fields: ["one": "1", "two": "2"]))
      == ProviderView(body: "héllo \"世界\"", items: [Row(id: "args", title: "one=1/two=2", actions: [])]))
}

@Test func existingExtensionDataDirectoriesArePrivateBeforeTheProgramRuns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(
    root, script: #"cat >/dev/null; /usr/bin/stat -f %Lp "$WICKET_DATA_DIR/.." "$WICKET_DATA_DIR""#)
  let data = root.appending(path: "data")
  let runner = ExtensionRunner(dataDirectory: data)
  let command = try command(ext)
  let child = runner.dataDirectory(for: command.id)
  let files = FileManager.default
  for folder in [data, child] {
    try files.createDirectory(at: folder, withIntermediateDirectories: false)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
  }
  let view = try await runner.run(command, request: .init(input: ""))
  #expect(view.body == "700\n700")
}

/// `./main.py` without its execute bit is not "missing": the repair brief says what is wrong.
@Test func aProgramWithoutItsExecuteBitSaysSo() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["./main.sh"]])
  let error = await #expect(throws: ExtensionFailure.self) {
    try await ExtensionRunner(dataDirectory: root).run(command(ext), request: .init(input: ""))
  }
  #expect(error?.message == "./main.sh isn't executable: run chmod +x ./main.sh in its folder")
}

@Test func theWorkingDirectoryIsTheExtensionsOwnFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["/usr/bin/python3", "cwd.py"]])
  try Data(
    "import os,json,sys; json.load(sys.stdin); print(json.dumps({'body':os.getcwd()}))".utf8
  ).write(to: ext.appending(path: "cwd.py"))
  let view = try await ExtensionRunner(dataDirectory: root).run(command(ext), request: .init(input: ""))
  let cwd = try #require(view.body)
  #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == ext.resolvingSymlinksInPath())
}

@Test(arguments: ["json", "exit", "timeout", "stdout", "stderr"])
func runnerFailuresAreBoundedAndKeepStderr(_ kind: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let scripts = [
    "json": "echo REPAIR >&2; echo '{bad'", "exit": "echo REPAIR >&2; exit 7",
    "timeout": "echo REPAIR >&2; sleep 30 & wait", "stdout": "echo REPAIR >&2; yes output",
    "stderr": "yes diagnostic >&2",
  ]
  let ext = try extensionFolder(root, script: scripts[kind]!)
  var runner = ExtensionRunner(dataDirectory: root)
  runner.deadline = .milliseconds(200)
  runner.outputLimit = 4096
  runner.stderrLimit = 4096
  let start = ContinuousClock.now
  do {
    _ = try await runner.run(command(ext), request: .init(input: ""))
    Issue.record("Expected failure")
  } catch {
    let text = error.localizedDescription
    #expect(text.contains("Stderr"))
    #expect(text.contains(kind == "stderr" ? "diagnostic" : "REPAIR"))
    #expect(
      text.contains(
        [
          "json": "Invalid extension view", "exit": "status 7", "timeout": "timed out",
          "stdout": "stdout exceeded", "stderr": "stderr exceeded",
        ][kind]!))
  }
  #expect(ContinuousClock.now - start < .seconds(5))
}

@MainActor @Test func nameKeywordAndFallbackStayInertAndCommandTypingReruns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, script: answering("Ready"), fields: ["name": "Deploy", "keyword": "ship", "fallback": true])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "ship"
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Deploy")
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Ready")
  model.navigator.input = "next"
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Ready")
  #expect(model.navigator.escape() && model.navigator.command == nil)
  model.navigator.input = "an unrelated sentence"
  await model.navigator.settled()
  #expect(model.navigator.results.first?.provider == "agent")
  #expect(model.navigator.results.contains { $0.row.id == "fallback" })
  await model.finish()
}

@MainActor @Test func rowsInsideACommandIgnoreLearnedUsageAndItsPicksAreNotRecorded() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let rows = [Row(id: "a", title: "Beta", actions: []), Row(id: "b", title: "Alpha", actions: [])]
  let list = String(decoding: try JSONEncoder().encode(ProviderView(items: rows)), as: UTF8.self)
  _ = try extensionFolder(root, script: "cat >/dev/null\nprintf '%s' '\(list)'")
  let history = UsageHistory(url: root.appending(path: "usage.json"))
  for _ in 0..<50 { history.record(Result(provider: "extension:test", row: rows[1]).id, input: "x") }
  let model = LauncherModel(history: history, folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  #expect(model.activateReturn())
  model.navigator.input = "x"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Beta", "Alpha"])
  let before = history.store.entries
  model.navigator.record(try #require(model.navigator.results.first))
  #expect(history.store.entries == before)
  await model.finish()
}

@MainActor @Test func extensionContractCanExpressInitialAppsAliasesAndCalculatorPresentation() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let row = Row(
    id: "app", title: "An Editor", actions: [.open(URL(fileURLWithPath: "/Applications/Editor.app"))],
    keywords: ["edit"])
  #expect(SearchIndex([row]).matches("edit").first == row)
  let view = ProviderView(items: [Row(id: "result", title: "4", actions: [.copy("4")], prominent: true)])
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
  _ = try extensionFolder(root, fields: ["match": ".*"])
  let manifest = try JSONDecoder().decode(
    ExtensionManifest.self, from: Data(contentsOf: root.appending(path: "extensions/test/wicket.json")))
  #expect(manifest.matches(""))
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = ""
  await model.navigator.settled()
  model.navigator.go(Address(id: "extension:test", fields: ["view": "all"]))
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:test")
  model.navigator.dismiss()
  #expect(model.navigator.command == nil)
  await model.finish()
}

@MainActor @Test func aNewFolderRunsAtRootWithoutAnyConfigEntryAndLeavesConfigAlone() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: root.appending(path: "extensions"), withIntermediateDirectories: true)
  try saveProviders([], in: root)
  let before = try Data(contentsOf: root.appending(path: "config.json"))
  let model = LauncherModel.testing(in: root)
  model.store.update {
    $0.providers = try! Configuration.load(at: root.appending(path: "config.json")).providers
  }
  model.extensions.start()
  let ext = try extensionFolder(root, name: "new", script: answering("Fresh"), fields: ["match": "^new$"])
  #expect(await eventually { model.extensions.commands["extension:new"] != nil })
  model.navigator.input = "new"
  await model.navigator.settled()
  #expect(
    model.navigator.results.first?.provider == "extension:new"
      && model.navigator.results.first?.row.title == "Fresh")
  #expect(try Data(contentsOf: root.appending(path: "config.json")) == before)
  try FileManager.default.removeItem(at: ext)
  #expect(await eventually { model.extensions.commands.isEmpty })
  model.navigator.input = "newer"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["agent"])
  await model.finish()
}

@MainActor @Test func anUnchangedRescanLeavesARunningExtensionAlone() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let runs = root.appending(path: "runs")
  _ = try extensionFolder(
    root, script: "echo run >> '\(runs.path)'\nsleep 0.3\n" + answering("Slow"), fields: ["match": "^slow$"])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "slow"
  #expect(await eventually { FileManager.default.fileExists(atPath: runs.path) })
  await model.extensions.reload()
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Slow")
  #expect(try String(contentsOf: runs, encoding: .utf8) == "run\n")
  await model.finish()
}

@MainActor @Test func aSwitchedOffExtensionShowsNoRowAndDoesNotRunInAQuery() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appending(path: "ran")
  _ = try extensionFolder(
    root, script: "touch '\(marker.path)'\n" + answering("Off"),
    fields: ["name": "Deploy", "keyword": "ship", "match": "^ship$"])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test", enabled: false)] }
  await model.extensions.reload()
  model.navigator.input = "ship"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["agent"])
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  model.store.update { $0.providers = [.init("extension:test")] }
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Off")
  await model.finish()
}

@MainActor @Test func newerTypingAndQuitStopActualExtensionProcesses() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appending(path: "pid")
  _ = try extensionFolder(
    root, script: "echo $$ > '\(marker.path)'\nsleep 30\n" + answering("Late"), fields: ["match": "^slow$"])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  // The shell creates the file before it writes the PID into it.
  func written() -> Int32? {
    (try? String(contentsOf: marker, encoding: .utf8)).flatMap {
      Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
  model.navigator.input = "slow"
  #expect(await eventually { written() != nil })
  let pid = try #require(written())
  model.navigator.input = "fast"
  await model.navigator.settled()
  #expect(await eventually { !isRunning(pid) })
  #expect(!model.navigator.results.contains { $0.row.title == "Late" })
  try FileManager.default.removeItem(at: marker)
  model.navigator.input = "slow"
  #expect(await eventually { written() != nil })
  let next = try #require(written())
  await model.finish()
  #expect(!isRunning(next))
}

@MainActor @Test func runActionFieldsPersistAsJSONWhileTypingInsideTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["/usr/bin/python3", "echo.py"]])
  try Data(
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':r['fields'].get('view','')+':'+r['input']}))"
      .utf8
  ).write(to: ext.appending(path: "echo.py"))
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  #expect(model.activateReturn())
  await model.navigator.settled()
  model.navigator.go(Address(id: "extension:test", fields: ["view": "one"]))
  await model.navigator.settled()
  #expect(model.navigator.body == "one:")
  model.navigator.input = "next"
  await model.navigator.settled()
  #expect(model.navigator.body == "one:next")
  #expect(model.navigator.escape() && model.navigator.command == nil)
  await model.finish()
}

/// A hidden run hides the panel before its program runs. A clean exit with nothing to show (no output, or
/// an old `{"close":true}`) leaves it hidden; a failure or a view opens it on its command without running
/// again, or while the panel is up says so in one line. A visible run with nothing to show is an error that
/// says how to fix it.
@MainActor @Test func aHiddenRunHidesThePanelAndShowsItOnlyForSomethingToSee() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "shut",
    script: """
      line=$(cat); echo "$line" >> log.jsonl
      case "$line" in
        *'"input":"old"'*) echo '{"close":true}';;
        *'"input":"quiet"'*) ;;
        *'"input":"fail"'*) echo broke >&2; exit 1;;
        *) echo '{"items":[{"id":"why","title":"Nothing moved","subtitle":"No window","actions":[]}]}';;
      esac
      """, fields: ["name": "Shut"])
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  surface.onEffect = { if $0 == .hide { model.navigator.dismiss() } }
  let row = Result(provider: "extension:shut", row: Row(id: "x", title: "x", actions: []))
  func runHidden(_ input: String) {
    model.navigator.activate(.run(Address(input: input, hidden: true)), from: row)
  }

  // Done: the panel hid as Return was pressed and stays hidden.
  for input in ["old", "quiet"] {
    runHidden(input)
    #expect(!surface.shown)
    await model.navigator.settled()
    #expect(!surface.shown && surface.shows == 0 && model.navigator.command == nil)
  }
  let sent = try requests(in: root.appending(path: "extensions/shut"))
  #expect(sent.count == 2 && sent.allSatisfy(\.submitted))

  // A failure with the panel hidden opens it on the report, and nothing runs again.
  runHidden("fail")
  await model.navigator.settled()
  #expect(surface.shows == 1 && model.navigator.command?.problem?.contains("broke") == true)
  #expect(try requests(in: root.appending(path: "extensions/shut")).count == 3)

  // A view while the user opened the panel again: one line, and the screen stays.
  _ = model.navigator.escape()
  await model.navigator.settled()
  runHidden("view")
  surface.shown = true
  await model.navigator.settled()
  #expect(surface.shows == 1 && model.navigator.command == nil)
  #expect(model.navigator.actionProblem == "Shut: Nothing moved: No window")

  // Not hidden, nothing to show is an error that names the fix.
  for input in ["old", "quiet"] {
    model.navigator.go(Address(id: "extension:shut", input: input), submitted: true)
    await model.navigator.settled()
    #expect(model.navigator.command?.problem?.contains(#""hidden":true"#) == true)
  }
  #expect(throws: ProviderView.Empty.self) {
    try JSONDecoder().decode(ProviderView.self, from: Data(#"{"close":true}"#.utf8))
  }
}

/// A hidden run's failure over a kept conversation shows the panel on the conversation with the failure as
/// the footer's line, until the user's next input.
@MainActor @Test func aHiddenFailureOverAConversationIsItsFooterUntilTheNextInput() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "shut", script: "echo broke >&2; exit 1", fields: ["name": "Shut"])
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  surface.onEffect = { if $0 == .hide { model.navigator.dismiss() } }
  try await finishTurn(model, "why", "Because.")
  var footers: [String?] = []
  surface.onDraw = { footers.append(model.navigator.presentation.agent?.footer) }
  let row = Result(provider: "extension:shut", row: Row(id: "x", title: "x", actions: []))
  model.navigator.activate(.run(Address(input: "", hidden: true)), from: row)
  #expect(!surface.shown)
  await model.navigator.settled()
  #expect(surface.shows == 1 && model.navigator.agentScreen != nil && model.navigator.command == nil)
  #expect(footers.last == "Shut: Extension exited with status 1")
  model.navigator.editInput("and")
  #expect(footers.last == "Continuing conversation")
}

/// `hidden` in a manifest makes a submit command's Return a hidden run; it means nothing without submit.
@MainActor @Test func aHiddenSubmitCommandsReturnIsAHiddenRun() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "quick", fields: ["submit": true, "hidden": true])
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  model.navigator.go(Address(id: "extension:quick"))
  await model.navigator.settled()
  model.navigator.input = "now"
  guard case .run(let address)? = model.navigator.returnAction?.kind else {
    Issue.record("Return sends no run")
    return
  }
  #expect(address.hidden && address.input == "now")
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      ExtensionManifest.self, from: Data(#"{"contract":2,"name":"x","command":["x"],"hidden":true}"#.utf8))
  }
}

/// A linked `extensions/` folder is watched where it points, and a linked extension inside it is found.
@MainActor @Test func linkedExtensionFoldersAreFoundAndWatched() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let real = root.appending(path: "dotfiles/extensions")
  try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: root.appending(path: "extensions"), withDestinationURL: real)
  let host = ExtensionHost(folder: root, bundled: nil)
  host.start()
  await host.firstScan()
  let source = try extensionFolder(root.appending(path: "elsewhere"), name: "weather")
  try FileManager.default.createSymbolicLink(at: real.appending(path: "weather"), withDestinationURL: source)
  #expect(await eventually { host.commands["extension:weather"] != nil })
  await host.shutdown()
}

@MainActor @Test func linkedExtensionTargetsStayWatchedThroughRetargetingAndRecreation() async throws {
  let root = try scratch().resolvingSymlinksInPath()
  let files = FileManager.default
  defer { try? files.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  let checkouts = root.appending(path: "checkouts")
  let first = checkouts.appending(path: "first")
  let second = checkouts.appending(path: "second")
  let link = extensions.appending(path: "weather")
  for folder in [extensions, first, second] {
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  try files.createSymbolicLink(atPath: link.path, withDestinationPath: "../checkouts/first")

  func writeManifest(_ json: String, in folder: URL) throws {
    try Data(json.utf8).write(to: folder.appending(path: "wicket.json"), options: .atomic)
  }

  let host = ExtensionHost(folder: root, bundled: nil)
  let id = "extension:weather"
  var changes: [Set<String>] = []
  host.onCatalogChange = { changes.append($0) }
  host.start()
  await host.firstScan()
  #expect(host.watchRoots == [extensions.path, first.path])
  #expect(host.ids.isEmpty)

  try writeManifest("{", in: first)
  #expect(await eventually(within: .seconds(3)) { host.problems[id] != nil })
  try writeManifest(#"{"name":"Weather","items":[]}"#, in: first)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Weather" })
  let identical = #"{"name":"Forecast","items":[]}"#
  try writeManifest(identical, in: first)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Forecast" })

  try writeManifest(identical, in: second)
  let replacement = root.appending(path: "replacement")
  try files.createSymbolicLink(at: replacement, withDestinationURL: second)
  let beforeRetarget = changes
  try #require(rename(replacement.path, link.path) == 0)
  #expect(await eventually(within: .seconds(3)) { host.watchRoots == [extensions.path, second.path] })
  #expect(changes == beforeRetarget)
  try writeManifest(#"{"name":"Local forecast","items":[]}"#, in: second)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Local forecast" })

  try files.removeItem(at: second)
  #expect(await eventually(within: .seconds(3)) { host.commands[id] == nil })
  #expect(host.watchRoots == [extensions.path, checkouts.path])
  try files.createDirectory(at: second, withIntermediateDirectories: false)
  try writeManifest(identical, in: second)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Forecast" })
  #expect(host.watchRoots == [extensions.path, second.path])
  await host.shutdown()
}

@MainActor @Test func linkedExtensionReturnsWhenItsWholeCheckoutIsRestored() async throws {
  let root = try scratch().resolvingSymlinksInPath()
  let files = FileManager.default
  defer { try? files.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  let repos = root.appending(path: "repos")
  let checkout = repos.appending(path: "checkout")
  let target = checkout.appending(path: "weather")
  for folder in [extensions, target] {
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  try Data(#"{"name":"Weather","items":[]}"#.utf8).write(to: target.appending(path: "wicket.json"))
  try files.createSymbolicLink(at: extensions.appending(path: "weather"), withDestinationURL: target)

  let host = ExtensionHost(folder: root, bundled: nil)
  let id = "extension:weather"
  host.start()
  await host.firstScan()
  #expect(host.commands[id]?.manifest.name == "Weather")
  #expect(host.watchRoots == [extensions.path, target.path])

  let moved = root.appending(path: "moved")
  try files.moveItem(at: checkout, to: moved)
  #expect(await eventually(within: .seconds(3)) { host.commands[id] == nil })
  #expect(host.watchRoots == [extensions.path, repos.path])
  try files.moveItem(at: moved, to: checkout)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Weather" })
  #expect(host.watchRoots == [extensions.path, target.path])
  await host.shutdown()
}

@MainActor @Test func linkedExtensionFollowsAnIntermediateSymlinkRetarget() async throws {
  let root = try scratch().resolvingSymlinksInPath()
  let files = FileManager.default
  defer { try? files.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  let releases = root.appending(path: "releases")
  let current = releases.appending(path: "current")
  let first = root.appending(path: "versions/first/weather")
  let second = root.appending(path: "versions/second/weather")
  for folder in [extensions, releases, first, second] {
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  let nextManifest = second.appending(path: "wicket.json")
  try Data(#"{"name":"First","items":[]}"#.utf8).write(to: first.appending(path: "wicket.json"))
  try Data(#"{"name":"Second","items":[]}"#.utf8).write(to: nextManifest)
  try files.createSymbolicLink(atPath: current.path, withDestinationPath: "../versions/first")
  try files.createSymbolicLink(
    atPath: extensions.appending(path: "weather").path, withDestinationPath: "../releases/current/weather")

  let host = ExtensionHost(folder: root, bundled: nil)
  let id = "extension:weather"
  host.start()
  await host.firstScan()
  #expect(host.commands[id]?.manifest.name == "First")
  #expect(host.watchRoots == [extensions.path, releases.path, first.path])

  let replacement = root.appending(path: "replacement")
  try files.createSymbolicLink(atPath: replacement.path, withDestinationPath: "../versions/second")
  try #require(rename(replacement.path, current.path) == 0)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Second" })
  #expect(host.watchRoots == [extensions.path, releases.path, second.path])
  try Data(#"{"name":"Edited","items":[]}"#.utf8).write(to: nextManifest, options: .atomic)
  #expect(await eventually(within: .seconds(3)) { host.commands[id]?.manifest.name == "Edited" })
  await host.shutdown()
}

@MainActor @Test func contractOneProgramsShowMigrationRepairsWhileItemsOnlyManifestsStillWork() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for (id, json) in [
    ("implicit", #"{"name":"Implicit","command":["/bin/sh","main.sh"],"match":".+"}"#),
    ("explicit", #"{"contract":1,"name":"Explicit","command":["/bin/sh","main.sh"],"arguments":[]}"#),
    (
      "links",
      #"{"name":"Links","items":[{"id":"link","title":"Example","actions":[{"type":"open","url":"https://example.com"}]}]}"#
    ),
  ] {
    let folder = try extensionFolder(root, name: id, script: "touch ran")
    try Data(json.utf8).write(to: folder.appending(path: "wicket.json"))
  }
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.input = ""
  await model.navigator.settled()
  for id in ["implicit", "explicit"] {
    let provider = "extension:" + id
    #expect(model.extensions.commands[provider] == nil)
    let repair = try #require(model.navigator.results.first { $0.provider == provider })
    #expect(repair.row.title.hasSuffix("needs repair"))
    #expect(repair.row.subtitle == "Update the manifest and program to contract 2")
    guard case .run(let address)? = repair.row.actions.first?.kind else {
      Issue.record("Repair does not open the agent")
      continue
    }
    #expect(address.input?.contains("read request.fields and request.action") == true)
    #expect(address.input?.contains(#"set "contract": 2"#) == true)
    let marker = root.appending(path: "extensions/\(id)/ran")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
  #expect(model.extensions.commands["extension:links"]?.manifest.contract == 1)
  model.navigator.input = "Example"
  await model.navigator.settled()
  #expect(model.navigator.results.contains { $0.provider == "extension:links" && $0.row.title == "Example" })
  await model.finish()
}
