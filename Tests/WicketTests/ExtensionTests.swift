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
  var manifest: [String: Any] = ["name": name, "keyword": name, "command": ["/bin/sh", "main.sh"]]
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

@Test func completeExtensionWireContract() throws {
  #expect(
    Result(provider: "extension:a", row: Row(id: "b:c", title: "A", actions: [])).id
      != Result(provider: "extension:a:b", row: Row(id: "c", title: "B", actions: [])).id)
  let view = ProviderView(
    body: "<stat label=\"Total\" value=\"42\"/>", items: [Row(id: "more", title: "More", actions: [])],
    actions: [
      .open(URL(string: "https://example.com")!), .copy("42"), .paste("42"),
      .run(arguments: ["refresh", "42"]), .agent("Explain 42"),
    ])
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
  for json in [
    #"{"items":[{"id":"x","title":"X","actions":[]},{"id":"x","title":"X","actions":[]}]}"#,
    #"{}"#, #"{"type":"detail","metadata":[]}"#, #"{"actions":[]}"#,
    #"{"items":[{"id":"","title":"X","actions":[]}]}"#,
    #"{"items":[{"id":"x","title":"X","actions":[{"type":"open","url":"javascript:alert(1)"}]}]}"#,
  ] {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8)) }
  }
  // `type`, `metadata` and other unknown keys are ignored.
  #expect(
    try JSONDecoder().decode(
      ProviderView.self,
      from: Data(#"{"type":"detail","body":"hi","metadata":[{"label":"a","value":"b"}],"extra":1}"#.utf8))
      == ProviderView(body: "hi"))
  for manifest in [#"{"name":"Bad","command":[]}"#, #"{"name":"Bad","command":["echo"],"match":"["}"#] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ExtensionManifest.self, from: Data(manifest.utf8))
    }
  }
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
  // Installed 0.1.x extensions keep working: `type` is ignored, `rows` reads as items, `metadata` is gone.
  #expect(try decode(#"{"type":"detail","body":"hi"}"#) == ProviderView(body: "hi"))
  #expect(try decode(#"{"type":"list","rows":[\#(itemJSON)]}"#) == ProviderView(items: [item]))
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "test"
  await model.settled()
  #expect(model.enterSelected())
  await model.settled()
  #expect(model.body == "## Berlin" && model.results.map(\.row.id) == ["a", "b"])
  #expect(model.viewActions == [.copy("view")])
  #expect(model.selected?.row.id == "a" && model.selected?.row.actions.first == .copy("one"))
  model.move(1)
  #expect(model.selected?.row.id == "b")
  model.move(1)
  #expect(model.selected?.row.id == "b")
  await model.finish()
}

@MainActor @Test func aPatternResultWithABodyOnlyOffersToEnterTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(body: "## Berlin", items: [Row(id: "a", title: "Inner", actions: [])])
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(
    root, script: "cat >/dev/null\nprintf '%s' '\(json)'", fields: ["match": "^weather"])
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "weather berlin"
  await model.settled()
  #expect(model.results.first { $0.provider == "extension:test" }?.row.id == "detail")
  #expect(!model.results.contains { $0.row.title == "Inner" })
  await model.finish()
}

func command(_ folder: URL) throws -> ExtensionCommand {
  try #require(
    ExtensionHost.discover(folder.deletingLastPathComponent()).0["extension:" + folder.lastPathComponent])
}

@Test func requestIsJSONAndTheProgramRunsFromItsOwnFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, script: answering("Hello"))
  #expect(
    try await ExtensionRunner().run(command(ext), request: .init(input: "hello"))
      == .init(items: [Row(id: "one", title: "Hello", actions: [.copy("Hello")])]))
  try Data(
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':r['input'],'items':[{'id':'args','title':'/'.join(r['arguments']),'actions':[]}]}))"
      .utf8
  ).write(to: ext.appending(path: "echo.py"))
  let data = try JSONSerialization.data(withJSONObject: [
    "name": "Echo", "command": ["/usr/bin/python3", "echo.py"],
  ])
  try data.write(to: ext.appending(path: "wicket.json"))
  #expect(
    try await ExtensionRunner().run(
      command(ext), request: .init(input: "héllo \"世界\"", arguments: ["one", "two"]))
      == ProviderView(body: "héllo \"世界\"", items: [Row(id: "args", title: "one/two", actions: [])]))
}

@Test func theWorkingDirectoryIsTheExtensionsOwnFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["/usr/bin/python3", "cwd.py"]])
  try Data(
    "import os,json,sys; json.load(sys.stdin); print(json.dumps({'body':os.getcwd()}))".utf8
  ).write(to: ext.appending(path: "cwd.py"))
  let view = try await ExtensionRunner().run(command(ext), request: .init(input: ""))
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
  var runner = ExtensionRunner()
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "ship"
  await model.settled()
  #expect(model.results.first?.row.title == "Deploy")
  #expect(model.enterSelected())
  await model.settled()
  #expect(model.results.first?.row.title == "Ready")
  model.input = "next"
  await model.settled()
  #expect(model.results.first?.row.title == "Ready")
  #expect(model.escape() && model.command == nil)
  model.input = "an unrelated sentence"
  await model.settled()
  #expect(model.results.first?.provider == "agent")
  #expect(model.results.contains { $0.row.id == "fallback" })
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
  let model = LauncherModel(providers: [], history: history, folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "test"
  await model.settled()
  #expect(model.enterSelected())
  model.input = "x"
  await model.settled()
  #expect(model.results.map(\.row.title) == ["Beta", "Alpha"])
  let before = history.store.entries
  model.record(try #require(model.results.first))
  #expect(history.store.entries == before)
  await model.finish()
}

@MainActor @Test func extensionContractCanExpressInitialAppsAliasesAndCalculatorPresentation() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let row = Row(
    id: "app", title: "An Editor", actions: [.open(URL(fileURLWithPath: "/Applications/Editor.app"))],
    keywords: ["edit"])
  #expect(SearchIndex([(row, [])]).search("edit", usage: UsageStore()).first == row)
  let view = ProviderView(items: [Row(id: "result", title: "4", actions: [.copy("4")], prominent: true)])
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
  _ = try extensionFolder(root, fields: ["match": ".*"])
  let manifest = try JSONDecoder().decode(
    ExtensionManifest.self, from: Data(contentsOf: root.appending(path: "extensions/test/wicket.json")))
  #expect(manifest.matches(""))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = ""
  await model.settled()
  model.rerun("extension:test", arguments: ["refresh"])
  await model.settled()
  #expect(model.command?.id == "extension:test")
  model.dismiss()
  #expect(model.command == nil)
  await model.finish()
}

@MainActor @Test func aNewFolderRunsAtRootWithoutAnyConfigEntryAndLeavesConfigAlone() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: root.appending(path: "extensions"), withIntermediateDirectories: true)
  try saveProviders([], in: root)
  let before = try Data(contentsOf: root.appending(path: "config.json"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [] }
  model.extensions.start()
  let ext = try extensionFolder(root, name: "new", script: answering("Fresh"), fields: ["match": "^new$"])
  #expect(await eventually { model.extensions.commands["extension:new"] != nil })
  model.input = "new"
  await model.settled()
  #expect(model.results.first?.provider == "extension:new" && model.results.first?.row.title == "Fresh")
  #expect(try Data(contentsOf: root.appending(path: "config.json")) == before)
  try FileManager.default.removeItem(at: ext)
  #expect(await eventually { model.extensions.commands.isEmpty })
  model.input = "newer"
  await model.settled()
  #expect(model.results.map(\.provider) == ["agent"])
  await model.finish()
}

@MainActor @Test func anUnchangedRescanLeavesARunningExtensionAlone() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let runs = root.appending(path: "runs")
  _ = try extensionFolder(
    root, script: "echo run >> '\(runs.path)'\nsleep 0.3\n" + answering("Slow"), fields: ["match": "^slow$"])
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "slow"
  #expect(await eventually { FileManager.default.fileExists(atPath: runs.path) })
  await model.extensions.reload()
  await model.settled()
  #expect(model.results.first?.row.title == "Slow")
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test", enabled: false)] }
  await model.extensions.reload()
  model.input = "ship"
  await model.settled()
  #expect(model.results.map(\.provider) == ["agent"])
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  model.store.update { $0.providers = [.init("extension:test")] }
  model.refresh()
  await model.settled()
  #expect(model.results.first?.row.title == "Off")
  await model.finish()
}

@MainActor @Test func newerTypingAndQuitStopActualExtensionProcesses() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appending(path: "pid")
  _ = try extensionFolder(
    root, script: "echo $$ > '\(marker.path)'\nsleep 30\n" + answering("Late"), fields: ["match": "^slow$"])
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  // The shell creates the file before it writes the PID into it.
  func written() -> Int32? {
    (try? String(contentsOf: marker, encoding: .utf8)).flatMap {
      Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
  model.input = "slow"
  #expect(await eventually { written() != nil })
  let pid = try #require(written())
  model.input = "fast"
  await model.settled()
  #expect(await eventually { !isRunning(pid) })
  #expect(!model.results.contains { $0.row.title == "Late" })
  try FileManager.default.removeItem(at: marker)
  model.input = "slow"
  #expect(await eventually { written() != nil })
  let next = try #require(written())
  await model.finish()
  #expect(!isRunning(next))
}

@MainActor @Test func runActionArgumentsPersistAsJSONWhileTypingInsideTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["/usr/bin/python3", "echo.py"]])
  try Data(
    "import json,sys; r=json.load(sys.stdin); print(json.dumps({'body':'/'.join(r['arguments'])+':'+r['input']}))"
      .utf8
  ).write(to: ext.appending(path: "echo.py"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.input = "test"
  await model.settled()
  #expect(model.enterSelected())
  await model.settled()
  model.rerun("extension:test", arguments: ["one"])
  await model.settled()
  #expect(model.body == "one:")
  model.input = "next"
  await model.settled()
  #expect(model.body == "one:next")
  #expect(model.escape() && model.command == nil)
  await model.finish()
}
