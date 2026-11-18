import AppKit
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
  model.input = "test"
  await model.settled()
  #expect(model.results.map(\.row.title) == ["Inline", "appstest"])
  model.store.update { $0.providers.reverse() }
  model.refresh()
  await model.settled()
  #expect(model.results.map(\.provider) == ["extension:pattern", "apps"])
  model.store.update { $0.providers[$0.providers.firstIndex { $0.id == "apps" }!].enabled = false }
  model.refresh()
  await model.settled()
  #expect(model.results.map(\.provider) == ["extension:pattern"])
}

@MainActor @Test func oldQueriesCannotReplaceNewResults() async {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(apps: provider, history: UsageHistory(url: url))
  model.input = "old"
  #expect(await eventually { provider.waiting["old"] != nil })
  model.input = "new"
  #expect(await eventually { provider.waiting["new"] != nil })
  provider.waiting.removeValue(forKey: "new")?.resume(returning: .init(items: [row("New")]))
  #expect(await eventually { model.results.first?.row.title == "New" })
  provider.waiting.removeValue(forKey: "old")?.resume(returning: .init(items: [row("Old")]))
  await Task.yield()
  #expect(model.results.map(\.row.title) == ["New"])
}

@MainActor @Test func refreshingNeverPublishesAnEmptyIntermediateList() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let provider = TestProvider("apps", delayed: true)
  let model = LauncherModel(
    apps: provider, history: UsageHistory(url: folder.appending(path: "usage.json")))
  var sizes: [Int] = []
  model.onResultsChange = { sizes.append(model.results.count) }
  model.input = "first"
  #expect(await eventually { provider.waiting["first"] != nil })
  provider.waiting.removeValue(forKey: "first")?.resume(returning: .init(items: [row("first")]))
  #expect(await eventually { !model.isRefreshing })
  sizes.removeAll()
  model.input = "second"
  #expect(model.results.count == 1 && sizes.isEmpty)
  #expect(await eventually { provider.waiting["second"] != nil })
  provider.waiting.removeValue(forKey: "second")?.resume(returning: .init(items: [row("second")]))
  #expect(await eventually { !model.isRefreshing })
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
  model.input = "weather"
  #expect(await eventually { !model.isRefreshing && model.results.count == 2 })
  let chosen = try #require(model.results.first { $0.provider == "apps" })
  model.select(chosen.id)
  let top = controller.panel.frame.maxY
  try Data().write(to: gate)
  await model.settled()
  #expect(
    model.selection == chosen.id
      && model.results.map(\.provider) == [
        "extension:weather", "extension:weather", "extension:weather", "apps",
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
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.input = "test"
  await model.settled()
  model.go(Address(id: "extension:test", arguments: [:]))
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

/// A pattern for `> text` whose row enters it with that text: slow for a `B`, very slow for a `Z`, failing
/// for `fail`. The agent
/// is a fake, so a question would start nothing real.
@MainActor private func echoLauncher(transcriber: (() -> any Transcriber)? = nil) async throws -> (
  LauncherModel, PaletteController, URL
) {
  let root = try scratch()
  _ = try extensionFolder(
    root, name: "echo",
    script: """
      import json,sys,time
      text = json.load(sys.stdin)['input']
      if 'B' in text or text == 'slow': time.sleep(0.4)
      if 'Z' in text: time.sleep(3)
      if text == '> fail': sys.exit(1)
      print(json.dumps({'items':[{'id':'run','title':text,'actions':[{'type':'run','input':text}]}]}))
      """, fields: ["match": "^> ", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root, transcriber: transcriber)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:echo")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "> A"
  await model.settled()
  #expect(model.selected?.row.title == "> A")
  return (model, controller, root)
}
@MainActor private func press(
  _ controller: PaletteController, _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []
) {
  #expect(controller.panel.route(voiceKey(code, text, flags)))
}

@MainActor @Test func returnAndCommandKNeverActOnTheRowsOfAnEarlierInput() async throws {
  let (model, controller, root) = try await echoLauncher()
  defer { try? FileManager.default.removeItem(at: root) }
  // Edited, the rows of "> A" still show until this generation composes.
  model.input = "> Z"
  #expect(model.rowsOutdated)
  // ⌘K opens nothing on them; Return waits, through the hold and for the pattern Ask agent would stand
  // in for, showing that it works, then runs the row of "> Z", never Ask agent.
  press(controller, 40, "k", .command)
  #expect(model.actionsTitle == nil)
  press(controller, 36, "\r")
  #expect(await eventually { model.returnWaiting })
  #expect(await eventually(within: .seconds(8)) { model.command != nil })
  await model.settled()
  #expect(model.command?.id == "extension:echo" && model.input == "> Z" && !model.agent.active)
  #expect(!model.returnWaiting)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aPendingPatternBlocksOnlyTheImplicitAskAgent() async throws {
  let (model, controller, root) = try await echoLauncher()
  defer { try? FileManager.default.removeItem(at: root) }
  model.input = "> Z"
  // Published after the hold, with the pattern still running: ⌘K works at once.
  #expect(await eventually { !model.rowsOutdated })
  #expect(model.selected?.provider == "agent")
  press(controller, 40, "k", .command)
  #expect(model.actionsTitle == "Ask agent")
  press(controller, 53, "\u{1B}")
  // Ask agent chosen explicitly asks at once, without waiting for the pattern.
  model.select(model.selection)
  press(controller, 36, "\r")
  #expect(model.agent.active && model.agent.question == "> Z")
  controller.hide()
  await model.finish()
}

@MainActor @Test func returnAfterAFailedPatternDoesNotAskTheAgent() async throws {
  let (model, controller, root) = try await echoLauncher()
  defer { try? FileManager.default.removeItem(at: root) }
  model.input = "> fail"
  await model.settled()
  // Ask agent stands first only because the pattern failed: Return leaves it to the user to choose.
  #expect(model.results.first?.provider == "agent" && !model.returnWaits)
  press(controller, 36, "\r")
  await model.settled()
  #expect(!model.agent.active && model.command == nil)
  // Nor right after a refresh of the same input, while its pattern runs again.
  model.refresh()
  press(controller, 36, "\r")
  await model.settled()
  #expect(!model.agent.active && model.command == nil && model.input == "> fail")
  controller.hide()
  await model.finish()
}

@MainActor @Test func dictationClosesTheActionsOfTheRowItReplaced() async throws {
  let fake = FakeTranscriber()
  let (model, controller, root) = try await echoLauncher(transcriber: { fake })
  defer { try? FileManager.default.removeItem(at: root) }
  press(controller, 40, "k", .command)
  #expect(model.actionsTitle == "> A")
  // A dictated query replaces the input: the actions of "> A" close, and Return runs the new row.
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("> C"))
  #expect(await eventually { model.input == "> C" })
  #expect(model.actionsTitle == nil)
  model.stopVoice(.hidden)
  await model.settled()
  press(controller, 36, "\r")
  await model.settled()
  #expect(model.command?.id == "extension:echo" && model.input == "> C")
  controller.hide()
  await model.finish()
}

@MainActor @Test func escapeFromAnEntryComposesTheRootListItInterrupted() async throws {
  let (model, controller, root) = try await echoLauncher()
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .seconds(5)
  model.input = "> B"
  // Entering a slow command stops the root's refresh for "> B"; Escape calls the entry off.
  model.go(Address(id: "echo", input: "slow"), submitted: true)
  press(controller, 53, "\u{1B}")
  #expect(model.command == nil && model.input == "> B")
  #expect(await eventually(within: .seconds(5)) { model.selected?.row.title == "> B" })
  controller.hide()
  await model.finish()
}

@MainActor @Test func leavingTheEmptyConversationComposesTheRootItInterrupted() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "slow",
    script:
      "import json,sys,time\ntext = json.load(sys.stdin)['input']\ntime.sleep(0.4)\nprint(json.dumps({'items':[{'id':'row','title':'Root','actions':[]}]} if text == '' else {'close':True}))",
    fields: ["match": "^$", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root)
  model.arrivalDeadline = .seconds(5)
  model.store.update { $0.providers = [.init("extension:slow")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.input = "x"
  await model.settled()
  // The query cleared, a slow command followed before the root composed, then ⌘Return over it.
  var closed = false
  model.onClose = { closed = true }
  model.input = ""
  model.go(Address(id: "slow", input: "go"), submitted: true)
  model.askAgent()
  #expect(model.agent.active && model.command == nil)
  // The command it called off never answers into the conversation: its close would hide the panel.
  try await Task.sleep(for: .milliseconds(600))
  #expect(!closed)
  // Escape back: the root's interrupted generation composes again.
  #expect(model.escape() && !model.agent.active)
  #expect(await eventually(within: .seconds(5)) { model.results.first?.row.title == "Root" })
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
  model.input = "weather"
  // The list waits a moment for the matching pattern, then shows without it.
  #expect(model.results.isEmpty)
  #expect(await eventually { model.selected?.provider == "agent" })
  try Data().write(to: gate)
  await model.settled()
  #expect(model.selected?.provider == "extension:forecast")
  model.select(model.selection)  // Mouse or keyboard intent now pins the identity.
  let chosen = model.selection
  try FileManager.default.removeItem(at: gate)
  model.sourcesChanged([])
  #expect(model.selection == chosen)
  try Data().write(to: gate)
  await model.settled()
  #expect(model.selection == chosen)
  await model.finish()
}
