import Foundation
import Testing

@testable import WicketApp

@Test func viewsAndActionsHaveAnExplicitWireFormat() throws {
  let json =
    #"{"items":[{"id":"calc","title":"4","actions":[{"type":"copy","text":"4"}]},{"id":"app","title":"Finder","actions":[{"type":"open","url":"file:///System/Library/CoreServices/Finder.app"}]}]}"#
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  #expect(try JSONDecoder().decode(ProviderView.self, from: JSONEncoder().encode(view)) == view)
  #expect(
    try JSONDecoder().decode(ProviderRequest.self, from: Data(#"{"input":"2+2"}"#.utf8))
      == ProviderRequest(input: "2+2"))
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
  func view(for request: ProviderRequest) async throws -> ProviderView {
    if delayed { return await withCheckedContinuation { waiting[request.input] = $0 } }
    return .init(items: [row(id + request.input)])
  }
}

@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

@MainActor @Test func sourceOrderInTheFileNeverChangesResultsAndDisablingRemovesRows() async {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let model = LauncherModel(
    providers: [TestProvider("apps"), TestProvider("math")], history: UsageHistory(url: url),
    folder: url.deletingLastPathComponent())
  model.input = "test"
  #expect(await eventually { !model.isRefreshing && model.results.count == 3 })
  #expect(model.results.map(\.provider) == ["math", "agent", "apps"])
  #expect(model.results.map(\.id) == ["math:mathtest", "agent:ask", "apps:appstest"])
  model.store.update { $0.providers.reverse() }
  model.refresh()
  #expect(await eventually { !model.isRefreshing && model.results.count == 3 })
  #expect(model.results.map(\.provider) == ["math", "agent", "apps"])
  model.store.update { $0.providers[$0.providers.firstIndex { $0.id == "apps" }!].enabled = false }
  model.refresh()
  #expect(await eventually { model.results.count == 2 })
  #expect(model.results.map(\.provider) == ["math", "agent"])
}

@MainActor @Test func oldQueriesCannotReplaceNewResults() async {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(providers: [provider], history: UsageHistory(url: url))
  model.input = "old"
  #expect(await eventually { provider.waiting["old"] != nil })
  model.input = "new"
  #expect(await eventually { provider.waiting["new"] != nil })
  provider.waiting.removeValue(forKey: "new")?.resume(returning: .init(items: [row("New")]))
  #expect(await eventually { model.results.first?.row.title == "New" })
  provider.waiting.removeValue(forKey: "old")?.resume(returning: .init(items: [row("Old")]))
  await Task.yield()
  #expect(model.results.map(\.row.title) == ["New", "Ask agent"])
}

@MainActor @Test func mathUsesTheSameProviderContract() async throws {
  let provider: any Provider = MathProvider()
  let view = try await provider.view(for: ProviderRequest(input: "2+2"))
  #expect(
    view
      == .init(items: [
        Row(
          id: "result", title: "4", subtitle: "Copy result", icon: "equal", actions: [.copy("4")],
          prominent: true)
      ]))
}

@MainActor @Test func refreshingNeverPublishesAnEmptyIntermediateList() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(
    providers: [provider], history: UsageHistory(url: folder.appending(path: "usage.json")))
  var sizes: [Int] = []
  model.onResultsChange = { sizes.append(model.results.count) }
  model.input = "first"
  #expect(await eventually { provider.waiting["first"] != nil })
  provider.waiting.removeValue(forKey: "first")?.resume(returning: .init(items: [row("first")]))
  #expect(await eventually { !model.isRefreshing })
  sizes.removeAll()
  model.input = "second"
  #expect(model.results.count == 2 && sizes.isEmpty)
  #expect(await eventually { provider.waiting["second"] != nil })
  provider.waiting.removeValue(forKey: "second")?.resume(returning: .init(items: [row("second")]))
  #expect(await eventually { !model.isRefreshing })
  #expect(sizes == [2])
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
    providers: [TestProvider("apps")], history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root)
  model.store.update { $0.providers = [.init("extension:weather"), .init("apps")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "weather"
  #expect(await eventually { !model.isRefreshing && model.results.count == 3 })
  let chosen = try #require(model.results.first { $0.provider == "apps" })
  model.select(chosen.id)
  let top = controller.panel.frame.maxY
  try Data().write(to: gate)
  await model.settled()
  #expect(
    model.selection == chosen.id
      && model.results.map(\.provider) == [
        "extension:weather", "extension:weather", "extension:weather", "agent", "apps",
      ])
  #expect(controller.panel.frame.maxY == top)
  model.refresh()
  await model.settled()
  #expect(model.selection == chosen.id)
  try FileManager.default.removeItem(at: gate)
  model.input = "weather tomorrow"
  #expect(await eventually { !model.isRefreshing })
  #expect(model.selection == model.results.first?.id && model.selected?.provider == "agent")
  try Data().write(to: gate)
  await model.settled()
  #expect(model.selection == model.results.first?.id && model.selected?.provider == "extension:weather")
  // Even a query edited away and back before results arrive counts as a new query.
  try FileManager.default.removeItem(at: gate)
  model.move(2)
  model.input = "other"
  model.input = "weather tomorrow"
  #expect(await eventually { !model.isRefreshing })
  #expect(model.selection == model.results.first?.id)
  try Data().write(to: gate)
  await model.settled()
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.input = "test"
  await model.settled()
  model.go(Address(id: "extension:test", arguments: []))
  await model.settled()
  model.move(1)
  let chosen = model.selection
  try reply([c, b, a])
  model.refresh()
  await model.settled()
  #expect(model.selection == chosen && model.selected?.row.id == "b")
  try reply([c, a])
  model.refresh()
  await model.settled()
  #expect(model.selected?.row.id == "a")  // Previous index 1, rather than the first row.
  try reply([c])
  model.refresh()
  await model.settled()
  #expect(model.selected?.row.id == "c")  // Clamp a removed last row.
  try reply([])
  model.refresh()
  await model.settled()
  #expect(model.selection == nil)
  try reply([a, b])
  model.refresh()
  await model.settled()
  model.move(1)
  model.input = "new"
  await model.settled()
  #expect(model.selected?.row.id == "a")
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:forecast")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.input = "weather"
  #expect(model.selected?.provider == "agent")
  try Data().write(to: gate)
  await model.settled()
  #expect(model.selected?.provider == "extension:forecast")
  model.select(model.selection)  // Mouse or keyboard intent now pins the identity.
  let chosen = model.selection
  try FileManager.default.removeItem(at: gate)
  model.catalogChanged()
  #expect(model.selection == chosen)
  try Data().write(to: gate)
  await model.settled()
  #expect(model.selection == chosen)
  await model.finish()
}
