import AppKit
import Foundation
import Testing

@testable import WicketApp

// The transitions between screens as they are, recorded before the screens move to their own owners:
// what the panel would draw at each publish, which requests ran, and which effects happened. Races are
// driven by gates (a file an extension waits for, apps that answer when released), never by timing alone.

/// Twelve apps, held back on request until released, so the root can be kept waiting.
@MainActor private final class GatedApps: Provider {
  let id = "apps"
  var held = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func view(for request: ProviderRequest) async -> ProviderView {
    if held { await withCheckedContinuation { waiting.append($0) } }
    return .init(items: (0..<12).map { row("App \($0)") })
  }
  func release() {
    held = false
    for gate in waiting { gate.resume() }
    waiting.removeAll()
  }
}

/// What the panel would draw at each publish.
@MainActor private final class Trace {
  struct Frame: Equatable {
    var screen: String
    var input: String
    var rows: [String]
    var selection: String?
    var body: String?
    var busy: Bool
    var height: CGFloat
  }
  private(set) var frames: [Frame] = []
  init(_ model: LauncherModel) {
    model.onResultsChange = { [weak self, weak model] in
      guard let self, let model else { return }
      frames.append(
        Frame(
          screen: model.agent.active ? "agent" : model.command?.id ?? "root", input: model.input,
          rows: model.results.map(\.row.title), selection: model.selected?.row.title, body: model.body,
          busy: model.command?.busy == true,
          height: model.cardHeight(answer: PaletteLayout.answerMin, cap: PaletteLayout.answerMax)))
    }
  }
  /// The screens in the order they were drawn, each once per visit.
  var screens: [String] {
    frames.map(\.screen).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
  }
}

private let full = PaletteLayout.rowsHeight(8) + PaletteLayout.footer
private let one = PaletteLayout.rowsHeight(1) + PaletteLayout.footer

/// A root of twelve apps and these test commands, at input "a":
/// - `slow`: logs each request, then answers "Finished" (or what `answer` says) once `release` exists.
/// - `notes`: two manifest items, answered without a process.
/// - `page`, `other`: a page each, logged.
@MainActor private func transitions(
  answer: String = #"{"items":[{"id":"done","title":"Finished","actions":[]}]}"#
)
  async throws -> (LauncherModel, GatedApps, URL)
{
  let root = try scratch()
  let logged = "cat >> log.jsonl\necho >> log.jsonl\n"
  _ = try extensionFolder(
    root, name: "slow",
    script: logged + "while [ ! -e release ]; do sleep 0.01; done\nprintf '%s' '\(answer)'")
  for (name, body) in [("page", "# First page"), ("other", "# Second page")] {
    let view = String(decoding: try JSONEncoder().encode(ProviderView(body: body)), as: UTF8.self)
    _ = try extensionFolder(root, name: name, script: logged + "printf '%s' '\(view)'")
  }
  let notes = try extensionFolder(
    root, name: "notes",
    fields: [
      "items": ["Groceries", "Ideas"].map {
        ["id": $0.lowercased(), "title": $0, "actions": [["type": "copy", "text": $0]]]
      }
    ])
  var manifest =
    try JSONSerialization.jsonObject(with: Data(contentsOf: notes.appending(path: "wicket.json")))
    as! [String: Any]
  manifest.removeValue(forKey: "command")
  try JSONSerialization.data(withJSONObject: manifest).write(to: notes.appending(path: "wicket.json"))
  let apps = GatedApps()
  let model = LauncherModel(
    apps: apps, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: nil)
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  model.input = "a"
  await model.settled()
  #expect(model.results.count > 8 && model.sizedRows == 8)
  return (model, apps, root)
}

private func release(_ root: URL, _ name: String = "slow") throws {
  try Data().write(to: root.appending(path: "extensions/\(name)/release"))
}
private func logged(_ root: URL, _ name: String = "slow") throws -> [ProviderRequest] {
  try requests(in: root.appending(path: "extensions/" + name))
}

@MainActor @Test func aSlowListShowsRunningAtTheDeadlineThenItsOutputInOneStep() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let trace = Trace(model)
  model.arrivalDeadline = .milliseconds(30)
  model.go(Address(id: "slow"), submitted: true)
  // Recorded as it is: starting the request draws the root once more, unchanged.
  let rootFrame = try #require(trace.frames.first)
  #expect(trace.frames.count == 1 && rootFrame.screen == "root" && rootFrame.input == "a")
  #expect(rootFrame.rows.count == 13 && rootFrame.selection == "App 0" && rootFrame.height == full)
  #expect(await eventually { model.command != nil })
  #expect(
    trace.frames == [
      rootFrame, .init(screen: "extension:slow", input: "", rows: [], busy: true, height: one),
    ])
  try release(root)
  await model.settled()
  #expect(
    trace.frames.last
      == .init(
        screen: "extension:slow", input: "", rows: ["Finished"], selection: "Finished", busy: false,
        height: one))
  #expect(trace.screens == ["root", "extension:slow"])
  let sent = try logged(root)
  #expect(sent.count == 1 && sent[0].submitted && sent[0].input.isEmpty)
  await model.finish()
}

@MainActor @Test func theDeadlinePassingWhileAPageIsMeasuredShowsTheCommandThenThePage() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let trace = Trace(model)
  // Long enough for the process to answer first, under load too.
  model.arrivalDeadline = .seconds(1)
  var measuring: CheckedContinuation<Void, Never>?
  model.preparePage = { _, _ in await withCheckedContinuation { measuring = $0 } }
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { measuring != nil })
  #expect(model.command == nil)
  // The deadline shows the command, still busy and with no page, while the same render goes on.
  #expect(await eventually(within: .seconds(3)) { model.command != nil })
  #expect(model.command?.busy == true && model.body == nil && model.results.isEmpty)
  measuring?.resume()
  #expect(await eventually { model.body == "# First page" })
  #expect(
    trace.frames.map { [$0.screen, $0.body ?? "-", "\($0.busy)"] } == [
      ["root", "-", "false"], ["extension:page", "-", "true"], ["extension:page", "# First page", "false"],
    ])
  #expect(try logged(root, "page").count == 1)
  await model.finish()
}

@MainActor @Test func aLateAnswerOfALeftEntryChangesNothing() async throws {
  let (model, _, root) = try await transitions(answer: #"{"close":true}"#)
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .seconds(5)
  var closed = 0
  model.onClose = { closed += 1 }
  // Hidden while entering: the late close never hides anything.
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.dismiss()
  try release(root)
  try await Task.sleep(for: .milliseconds(100))
  #expect(closed == 0 && model.command == nil && model.input.isEmpty)
  // Replaced by another command: the late answer of the first is dropped.
  try FileManager.default.removeItem(at: root.appending(path: "extensions/slow/release"))
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 2 })
  model.go(Address(id: "notes"), submitted: true)
  #expect(model.command?.id == "extension:notes")
  try release(root)
  try await Task.sleep(for: .milliseconds(100))
  #expect(closed == 0 && model.command?.id == "extension:notes" && model.command?.problem == nil)
  await model.finish()
}

@MainActor @Test func aSecondEscapeWhileGoingBackWaitsForTheRoot() async throws {
  let (model, apps, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.go(Address(id: "notes"), submitted: true)
  #expect(model.command?.id == "extension:notes" && model.sizedRows == 2)
  let trace = Trace(model)
  apps.held = true
  #expect(model.escape())
  #expect(model.escape())
  // Still the command, exactly as it was, and nothing was drawn.
  #expect(model.command?.id == "extension:notes" && model.results.map(\.row.title) == ["Groceries", "Ideas"])
  #expect(trace.frames.isEmpty)
  apps.release()
  await model.settled()
  #expect(model.command == nil && model.input.isEmpty && model.sizedRows == 8)
  #expect(trace.screens == ["root"] && trace.frames.allSatisfy { $0.height == full })
  await model.finish()
}

@MainActor @Test func pageToPageRendersTheIncomingPageWhileTheOutgoingOneShows() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .seconds(5)
  var measured: [(page: String, shown: String?)] = []
  model.preparePage = { page, _ in measured.append((page.source, model.body)) }
  model.go(Address(id: "page"), submitted: true)
  await model.settled()
  model.go(Address(id: "other"), submitted: true)
  await model.settled()
  // The one renderer measures the second page while the first one is what the model shows.
  #expect(measured.map(\.page) == ["# First page", "# Second page"])
  #expect(measured.map(\.shown) == [nil, "# First page"])
  #expect(model.body == "# Second page")
  #expect(try logged(root, "page").count == 1 && logged(root, "other").count == 1)
  await model.finish()
}

@MainActor @Test func anImmediateDestinationRunsNoProcessAndEntersBeforeReturnReturns() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let trace = Trace(model)
  model.go(Address(id: "notes"), submitted: true)
  #expect(
    trace.frames == [
      .init(
        screen: "extension:notes", input: "", rows: ["Groceries", "Ideas"], selection: "Groceries",
        busy: false,
        height: PaletteLayout.rowsHeight(2) + PaletteLayout.footer)
    ])
  await model.finish()
}

@MainActor @Test func typingDuringAnEntryAppendsWhatWasAddedOrReplacesTheInput() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .seconds(5)
  // An addition to the old input is what is typed into the new one.
  model.go(Address(id: "slow", input: "x"), submitted: true)
  model.editInput("ab")
  #expect(model.command?.id == "extension:slow" && model.input == "xb")
  model.dismiss()
  model.input = "a"
  await model.settled()
  // Anything else is the new input as a whole, run once as typing, never submitted.
  model.go(Address(id: "slow"), submitted: true)
  model.editInput("z")
  #expect(model.command?.id == "extension:slow" && model.input == "z" && model.command?.busy == true)
  #expect(await eventually { (try? logged(root).contains { $0.input == "z" }) == true })
  try release(root)
  await model.settled()
  let typed = try logged(root).filter { $0.input == "z" }
  #expect(typed.count == 1 && !typed[0].submitted && model.results.map(\.row.title) == ["Finished"])
  await model.finish()
}

@MainActor @Test func speechDuringAnEntrySwitchesAndIsTheWholeInput() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let transcriber = FakeTranscriber()
  let voiced = LauncherModel(
    apps: GatedApps(), history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil, transcriber: { transcriber })
  await model.finish()
  voiced.extensions.onCatalogChange = nil
  await voiced.extensions.reload()
  voiced.store.update { $0.voice.enabled = true }
  voiced.input = "a"
  await voiced.settled()
  voiced.armVoice()
  transcriber.feeds[0].yield(.ready)
  #expect(await eventually { voiced.voice?.state == .listening })
  voiced.arrivalDeadline = .seconds(5)
  voiced.go(Address(id: "slow"), submitted: true)
  transcriber.feeds[0].yield(.transcript("is it done"))
  #expect(await eventually { voiced.command != nil })
  #expect(
    voiced.command?.id == "extension:slow" && voiced.input == "is it done" && voiced.voice?.active == true)
  // Speech waits its 350 ms before the rerun, which is never submitted.
  #expect(
    await eventually(within: .seconds(3)) {
      (try? logged(root).contains { $0.input == "is it done" }) == true
    })
  #expect(try logged(root).filter { $0.input == "is it done" }.allSatisfy { !$0.submitted })
  voiced.stopVoice(.edit)
  await voiced.finish()
}

@MainActor @Test func theActionPanelReturnsToItsPlaceAndDispatchesTheActionChosen() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(
    body:
      "## Links\n<row title=\"Docs\" open=\"https://example.com/docs\"/>\n<row title=\"Blog\" copy=\"blog\"/>",
    items: [
      Row(
        id: "twins", title: "Twins",
        actions: [
          .open(URL(string: "https://example.com/one")!, title: "Open"),
          .open(URL(string: "https://example.com/two")!, title: "Open"),
        ])
    ])
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(root, name: "links", script: "cat >/dev/null\nprintf '%s' '\(json)'")
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.go(Address(id: "links"), submitted: true)
  await model.settled()
  let turn = model.pageTurn
  model.move(1)
  model.move(1)
  #expect(model.selectedTarget == "#1")
  model.toggleActions()
  #expect(model.actionsTitle == "Blog" && model.selectedTarget == nil)
  #expect(model.escape())
  #expect(model.actionsTitle == nil && model.selectedTarget == "#1" && model.pageTurn == turn)
  // Two actions with one label: the second one chosen is the second one run, from the row it belongs to.
  model.move(1)
  model.toggleActions()
  #expect(model.results.map(\.row.title) == ["Open", "Open"])
  model.move(1)
  let picked = try #require(model.pick())
  #expect(picked.action.kind == .open(URL(string: "https://example.com/two")!))
  #expect(picked.from?.row.id == "twins" && model.actionsTitle == nil)
  // Typing into the panel's empty field closes it, and the text is the whole input.
  model.toggleActions()
  model.editInput("x")
  #expect(model.actionsTitle == nil && model.input == "x")
  // Cmd+Return closes it before asking.
  model.input = ""
  model.toggleActions()
  model.askAgent()
  #expect(model.actionsTitle == nil && model.agent.active && model.returnsOnEscape)
  await model.finish()
}

@MainActor @Test func cmdReturnOverARunningCommandKeepsItRunningAndEscapeRevealsItsResult() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .milliseconds(1)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.command?.busy == true })
  model.askAgent()
  #expect(model.agent.active && model.returnsOnEscape && model.askingAbout == "slow")
  try release(root)
  #expect(await eventually { model.command?.busy == false })
  // The result belongs to the command under the conversation.
  #expect(model.agent.active && model.results.isEmpty && model.command?.shown.view.items.count == 1)
  #expect(model.escape())
  #expect(!model.agent.active && model.results.map(\.row.title) == ["Finished"] && model.input.isEmpty)
  #expect(try logged(root).count == 1)
  await model.finish()
}

@MainActor @Test func aValidCloseUnderAnEmptyQuestionHidesThePanel() async throws {
  let (model, _, root) = try await transitions(answer: #"{"close":true}"#)
  defer { try? FileManager.default.removeItem(at: root) }
  var closed = 0
  model.onClose = { closed += 1 }
  model.arrivalDeadline = .milliseconds(1)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.command?.busy == true })
  model.askAgent()
  try release(root)
  // Recorded as it is: the submitted request's close is accepted even under the empty conversation.
  #expect(await eventually { closed == 1 })
  #expect(model.agent.active && model.returnsOnEscape)
  await model.finish()
}

@MainActor @Test func sendingFromOverARunningCommandStopsItAndBackRunsItAgain() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.arrivalDeadline = .milliseconds(1)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.command?.busy == true })
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.askAgent()
  model.editInput("why so slow")
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  #expect(model.command?.busy == false && !model.returnsOnEscape)
  fake.text("Because.")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  try release(root)
  #expect(model.escape())
  await model.settled()
  // Back on the command with a blank input and a fresh request, not the old one revealed.
  #expect(!model.agent.active && model.command?.id == "extension:slow" && model.input.isEmpty)
  let sent = try logged(root)
  #expect(sent.count == 2 && sent[0].submitted && !sent[1].submitted)
  #expect(model.results.map(\.row.title) == ["Finished"])
  await model.finish()
}

/// A root pattern for `> text`, held on `release` for inputs with B, failing for inputs with F.
@MainActor private func staleReturn() async throws -> (LauncherModel, PaletteController, URL) {
  let root = try scratch()
  _ = try extensionFolder(
    root, name: "echo",
    script: """
      import json,sys,time,os
      text = json.load(sys.stdin)['input']
      if 'F' in text: sys.exit(1)
      while 'B' in text and not os.path.exists('release'): time.sleep(0.01)
      print(json.dumps({'items':[{'id':'run','title':text,'actions':[{'type':'run','input':text}]}]}))
      """, fields: ["match": "^> ", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:echo")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "> A"
  await model.settled()
  return (model, controller, root)
}

@MainActor @Test func aWaitingReturnIsCalledOffByAnEditAPickOrHiding() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  for cancel in ["edit", "pick", "hide"] {
    model.input = "> B"
    controller.run()
    #expect(model.returnQueued && model.returnWaits)
    switch cancel {
    case "edit": model.editInput("> Bb")
    case "pick": model.select(model.results.first?.id)
    default:
      controller.hide()
      controller.show(orderFront: false, listen: false)
    }
    #expect(!model.returnQueued)
  }
  try release(root, "echo")
  await model.settled()
  #expect(model.command == nil && !model.agent.active)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aWaitingReturnRunsOnceAndNeverForAFailedPattern() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  // A failed pattern leaves the Return waiting: it never becomes Ask agent.
  model.input = "> F"
  controller.run()
  await model.settled()
  #expect(model.returnQueued && model.command == nil && !model.agent.active)
  #expect(model.results.contains { $0.row.id == "error" })
  // Replayed once, when the rows for what is typed arrive.
  model.input = "> B"
  controller.run()
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.command != nil })
  #expect(model.command?.id == "extension:echo" && model.input == "> B" && !model.returnQueued)
  await model.settled()
  #expect(model.command?.id == "extension:echo" && !model.agent.active)
  controller.hide()
  await model.finish()
}

@MainActor @Test func anItemHotkeyRunsItsProgramOnceAndShowsAFailureOnce() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "mover",
    script:
      "cat >> log.jsonl\necho >> log.jsonl\nwhile [ ! -e release ]; do sleep 0.01; done\necho nope >&2\nexit 1",
    fields: [
      "items": [
        ["id": "left", "title": "Left half", "actions": [["type": "run", "arguments": ["to": "left"]]]]
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  var shown = 0
  let press = Task { await model.press(HotkeyTarget(target: "extension:mover", item: "left")) { shown += 1 } }
  #expect(await eventually { (try? logged(root, "mover").count) == 1 })
  #expect(shown == 0 && model.command == nil)
  try release(root, "mover")
  await press.value
  #expect(
    shown == 1 && model.command?.id == "extension:mover" && model.command?.problem?.contains("nope") == true)
  let sent = try logged(root, "mover")
  #expect(sent.count == 1 && sent[0].submitted && sent[0].arguments == ["to": "left"])
  await model.settled()
  #expect(try logged(root, "mover").count == 1)
  await model.finish()
}

@MainActor @Test func theFieldIsWrittenOnlyWhenItsTextChanges() {
  final class CountingField: NSTextField {
    var writes = 0
    override var stringValue: String {
      didSet { writes += 1 }
    }
  }
  let field = CountingField(string: "")
  field.writes = 0
  SearchField.updateText("abc", in: field)
  SearchField.updateText("abc", in: field)
  #expect(field.writes == 1 && field.stringValue == "abc")
}
