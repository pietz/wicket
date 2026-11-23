import Foundation
import Testing

@testable import WicketApp

@Test func viewsAndActionsHaveAnExplicitWireFormat() throws {
  let json =
    #"{"items":[{"id":"calc","title":"4","actions":[{"type":"copy","text":"4"}]},{"id":"app","title":"Finder","actions":[{"type":"open","url":"file:///System/Library/CoreServices/Finder.app"}]}]}"#
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
}

@Test(arguments: [
  #"{"type":"list"}"#, #"{"items":{}}"#, #"{"body":1}"#,
  #"{"items":[{"id":"x","actions":[]}]}"#,
  #"{"items":[{"id":"x","title":"X","actions":[{"type":"shell"}]}]}"#,
  #"{"items":[{"id":"x","title":"X","actions":[{"type":"copy"}]}]}"#,
])
func badViewsFail(json: String) {
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  }
}

@MainActor
private final class TestProvider: Provider {
  let id: String
  var waiting: [String: CheckedContinuation<ProviderView, Never>] = [:]
  let delayed: Bool
  init(_ id: String, delayed: Bool = false) {
    self.id = id
    self.delayed = delayed
  }
  func view(for request: ProviderRequest) async -> ProviderView {
    if delayed { return await withCheckedContinuation { waiting[request.input] = $0 } }
    return .init(items: [row(id + request.input)])
  }
}

@MainActor
func eventually(within limit: Duration = .seconds(1), _ condition: () -> Bool) async -> Bool {
  for _ in 0..<Int(limit / Duration.milliseconds(5)) {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

@MainActor @Test func sourceOrderInTheFileNeverChangesResultsAndDisablingRemovesRows() async throws {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let root = url.deletingLastPathComponent()
  _ = try extensionFolder(root, name: "pattern", script: answering("Inline"), fields: ["match": "^test$"])
  let model = LauncherModel(apps: TestProvider("apps"), history: UsageHistory(url: url), folder: root)
  model.store.update { $0.providers = [.init("apps"), .init("extension:pattern")] }
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Inline", "appstest"])
  model.store.update { $0.providers.reverse() }
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["extension:pattern", "apps"])
  model.store.update { $0.providers[$0.providers.firstIndex { $0.id == "apps" }!].enabled = false }
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["extension:pattern"])
}

@MainActor @Test func oldQueriesCannotReplaceNewResults() async {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(apps: provider, history: UsageHistory(url: url))
  model.navigator.input = "old"
  #expect(await eventually { provider.waiting["old"] != nil })
  model.navigator.input = "new"
  #expect(await eventually { provider.waiting["new"] != nil })
  provider.waiting.removeValue(forKey: "new")?.resume(returning: .init(items: [row("New")]))
  #expect(await eventually { model.navigator.results.first?.row.title == "New" })
  provider.waiting.removeValue(forKey: "old")?.resume(returning: .init(items: [row("Old")]))
  await Task.yield()
  #expect(model.navigator.results.map(\.row.title) == ["New"])
}

@MainActor @Test func refreshingNeverPublishesAnEmptyIntermediateList() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(
    apps: provider, history: UsageHistory(url: folder.appending(path: "usage.json")))
  var sizes: [Int] = []
  let surface = RecordingSurface()
  model.navigator.surface = surface
  surface.onDraw = { sizes.append(model.navigator.results.count) }
  model.navigator.input = "first"
  #expect(await eventually { provider.waiting["first"] != nil })
  provider.waiting.removeValue(forKey: "first")?.resume(returning: .init(items: [row("first")]))
  #expect(await eventually { !model.root.isSearching })
  sizes.removeAll()
  model.navigator.input = "second"
  #expect(model.navigator.results.count == 1 && sizes.isEmpty)
  #expect(await eventually { provider.waiting["second"] != nil })
  provider.waiting.removeValue(forKey: "second")?.resume(returning: .init(items: [row("second")]))
  #expect(await eventually { !model.root.isSearching })
  #expect(sizes == [1])
}

@MainActor @Test func lateExtensionRowsKeepSelectionAndNewQueriesResetIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let response = root.appending(path: "response.json")
  let gate = root.appending(path: "release")
  let script = """
    import json,sys,time,pathlib
    json.load(sys.stdin)
    while not pathlib.Path('\(gate.path)').exists(): time.sleep(0.01)
    print(pathlib.Path('\(response.path)').read_text())
    """
  _ = try extensionFolder(
    root, name: "weather", script: script,
    fields: ["match": ".+", "command": ["/usr/bin/python3", "main.sh"]])
  let rows = ["a", "b", "c"].map { Row(id: $0, title: "Weather " + $0, actions: []) }
  try JSONEncoder().encode(ProviderView(items: rows)).write(to: response)
  let model = LauncherModel(
    apps: TestProvider("apps"), history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root)
  model.store.update { $0.providers = [.init("extension:weather"), .init("apps")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "weather"
  #expect(await eventually { !model.root.isSearching && model.navigator.results.count == 2 })
  let chosen = try #require(model.navigator.results.first { $0.provider == "apps" })
  model.navigator.select(chosen.id)
  let top = controller.panel.frame.maxY
  try Data().write(to: gate)
  await model.navigator.settled()
  #expect(
    model.navigator.selection == chosen.id
      && model.navigator.results.map(\.provider) == [
        "extension:weather", "extension:weather", "extension:weather", "apps",
      ])
  #expect(controller.panel.frame.maxY == top)
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.selection == chosen.id)
  try FileManager.default.removeItem(at: gate)
  model.navigator.input = "weather tomorrow"
  #expect(await eventually { !model.root.isSearching })
  #expect(
    model.navigator.selection == model.navigator.results.first?.id
      && !model.navigator.results.contains { $0.provider == "agent" })
  try Data().write(to: gate)
  await model.navigator.settled()
  #expect(
    model.navigator.selection == model.navigator.results.first?.id
      && model.navigator.selected?.provider == "extension:weather")
  // Even a query edited away and back before results arrive counts as a new query.
  try FileManager.default.removeItem(at: gate)
  model.navigator.move(2)
  model.navigator.input = "other"
  model.navigator.input = "weather tomorrow"
  #expect(await eventually { !model.root.isSearching })
  #expect(model.navigator.selection == model.navigator.results.first?.id)
  try Data().write(to: gate)
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

@MainActor @Test func commandRefreshKeepsIdentityAndFallsBackAtThePreviousPosition() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let response = root.appending(path: "response.json")
  _ = try extensionFolder(root, script: "cat >/dev/null\ncat '\(response.path)'", fields: ["match": ".+"])
  let a = row("a")
  let b = row("b")
  let c = row("c")
  func reply(_ rows: [Row]) throws {
    try JSONEncoder().encode(ProviderView(items: rows)).write(to: response, options: .atomic)
  }
  try reply([a, b, c])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  model.navigator.go(Address(id: "extension:test", fields: [:]))
  await model.navigator.settled()
  model.navigator.move(1)
  let chosen = model.navigator.selection
  try reply([c, b, a])
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.selection == chosen && model.navigator.selected?.row.id == "b")
  try reply([c, a])
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "a")  // Previous index 1, rather than the first row.
  try reply([c])
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "c")  // Clamp a removed last row.
  try reply([])
  model.navigator.refresh()
  await model.navigator.settled()
  #expect(model.navigator.selection == nil)
  try reply([a, b])
  model.navigator.refresh()
  await model.navigator.settled()
  model.navigator.move(1)
  model.navigator.input = "new"
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "a")
  await model.finish()
}

@MainActor @Test func returnRightAfterAnEditWaitsForTheRowsOfWhatIsTyped() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // A pattern for `> text` whose row enters it with that text, slower than the hold for a `B`.
  _ = try extensionFolder(
    root, name: "echo",
    script: """
      import json,sys,time
      text = json.load(sys.stdin)['input']
      if 'B' in text: time.sleep(0.4)
      print(json.dumps({'items':[{'id':'run','title':text,'actions':[{'type':'run','input':text}]}]}))
      """, fields: ["match": "^> ", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:echo")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "> A"
  await model.navigator.settled()
  // Return while the rows of "> A" still show, then while the list waits for the slow pattern without
  // Ask agent: it runs "> B" once that answers, never A and never the agent.
  model.navigator.input = "> B"
  controller.run()
  #expect(await eventually { !model.root.isSearching })
  #expect(!model.navigator.results.contains { $0.provider == "agent" })
  #expect(model.navigator.command == nil && !model.agent.active)
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(
    model.navigator.command?.id == "extension:echo" && model.navigator.input == "> B" && !model.agent.active)
  controller.hide()
  await model.finish()
}

@MainActor @Test func untouchedSelectionFollowsTheBestLateResultAndChosenExtensionSurvivesRefresh()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let gate = root.appending(path: "release")
  _ = try extensionFolder(
    root, name: "forecast",
    script: """
      import json,sys,time,pathlib
      json.load(sys.stdin)
      while not pathlib.Path('\(gate.path)').exists(): time.sleep(0.01)
      print(json.dumps({'items':[{'id':'weather','title':'Weather today','actions':[]}]}))
      """, fields: ["match": ".+", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:forecast")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.navigator.input = "weather"
  // The list waits a moment for the matching pattern, then shows without it, and without Ask agent.
  #expect(model.navigator.results.isEmpty)
  #expect(await eventually { !model.root.isSearching })
  #expect(!model.navigator.results.contains { $0.provider == "agent" })
  try Data().write(to: gate)
  await model.navigator.settled()
  #expect(model.navigator.selected?.provider == "extension:forecast")
  model.navigator.select(model.navigator.selection)  // Mouse or keyboard intent now pins the identity.
  let chosen = model.navigator.selection
  try FileManager.default.removeItem(at: gate)
  model.navigator.sourcesChanged([])
  #expect(model.navigator.selection == chosen)
  try Data().write(to: gate)
  await model.navigator.settled()
  #expect(model.navigator.selection == chosen)
  await model.finish()
}

@MainActor @Test func theRootSearchAloneDeliversThePanelsList() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "pattern", script: answering("Inline"), fields: ["match": "^te"])
  let model = LauncherModel(
    apps: TestProvider("apps"), history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.navigator.input = "test"
  await model.navigator.settled()
  // Headless searches without the panel: the same rows and reason, in the same order.
  var lists: [RootCommand.Output] = []
  model.root.search("test", speaking: false) { lists.append($0) }
  await model.root.settled()
  #expect(lists.last?.input == "test" && lists.last?.results.map(\.id) == model.navigator.results.map(\.id))
  #expect(model.navigator.results.map(\.row.title) == ["Inline", "appstest"])
  #expect(model.root.strongReason == "pattern result: extension:pattern" && !model.root.isSearching)
  await model.finish()
}

@MainActor @Test func aCancelledRootSearchDeliversNothing() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "pattern",
    script: answering("Late").replacingOccurrences(
      of: "cat >/dev/null\n", with: "cat >/dev/null\nwhile [ ! -e release ]; do sleep 0.01; done\n"),
    fields: ["match": "^te"])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  var delivered = 0
  model.root.search("test", speaking: false) { _ in delivered += 1 }
  #expect(
    model.root.pending == ["extension:pattern"] && model.root.isSearching
      && model.root.runningPatterns == ["extension:pattern"])
  model.root.cancel()
  #expect(model.root.pending.isEmpty && !model.root.isSearching && model.root.runningPatterns.isEmpty)
  try Data().write(to: root.appending(path: "extensions/pattern/release"))
  await model.root.settled()
  try await Task.sleep(for: .milliseconds(100))
  #expect(delivered == 0)
  await model.finish()
}
