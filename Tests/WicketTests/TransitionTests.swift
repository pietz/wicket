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
private let finished = #"{"items":[{"id":"done","title":"Finished","actions":[]}]}"#

@MainActor private func transitions(answer: String = finished)
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
  model.arrivalDeadline = .seconds(60)
  var measuring: CheckedContinuation<Void, Never>?
  model.preparePage = { _, _ in await withCheckedContinuation { measuring = $0 } }
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { measuring != nil })
  #expect(model.command == nil)
  // The deadline shows the command, still busy and with no page, while the same render goes on.
  model.passDeadline()
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
  // The entry's request is called off before it started, and the appended input runs once as typing.
  #expect(await eventually { (try? logged(root).count) == 1 })
  #expect(try logged(root).map { [$0.input, "\($0.submitted)"] } == [["xb", "false"]])
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
  #expect(try logged(root).count == 2)
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
      request = json.load(sys.stdin)
      open('log.jsonl', 'a').write(json.dumps(request) + '\\n')
      text = request['input']
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

// The gate before the screens move to their own owners: the panel's own frame at each switch, late
// deliveries after a switch was called off, repeated and queued Returns, layers over a page and native
// edits through the field editor.

@MainActor @Test func aSwitchWaitsAHundredAndFiftyMilliseconds() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(LauncherModel.testing(in: root, bundled: nil).arrivalDeadline == .milliseconds(150))
}

/// A panel that routes keys as if it had them, and records every frame it is given.
@MainActor private final class FramePanel: PalettePanel {
  var frames: [NSRect] = []
  override var isKeyWindow: Bool { true }
  override func setFrame(_ frame: NSRect, display: Bool) {
    frames.append(frame)
    super.setFrame(frame, display: display)
  }
}

/// The transitions' model in an offscreen panel whose renderer measures each page only once released.
@MainActor private final class Measured {
  let model: LauncherModel
  let controller: PaletteController
  let panel = FramePanel()
  let root: URL
  /// What the panel showed at each publish, with its frame then.
  private(set) var shown:
    [(screen: String, input: String, selection: String?, body: String?, busy: Bool, frame: NSRect)] = []
  private var held: [CheckedContinuation<Void, Never>] = []
  var measuring: Int { held.count }
  init(answer: String = finished) async throws {
    let (model, _, root) = try await transitions(answer: answer)
    self.model = model
    self.root = root
    controller = PaletteController(model: model, panel: panel)
    controller.show(orderFront: false, listen: false)
    await model.settled()
    let draw = model.onResultsChange
    model.onResultsChange = { [unowned self] in
      draw?()
      shown.append(
        (
          model.agent.active ? "agent" : model.command?.id ?? "root", model.input, model.selected?.row.title,
          model.body, model.command?.busy == true, panel.frame
        ))
    }
    let measure = model.preparePage
    model.preparePage = { [unowned self] page, turn in
      await withCheckedContinuation { held.append($0) }
      await measure?(page, turn)
    }
  }
  func release() {
    for gate in held { gate.resume() }
    held.removeAll()
  }
  func finish() async {
    controller.hide()
    await model.finish()
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor @Test func aMeasuredPageArrivesWithItsHeightInOneFrame() async throws {
  let panel = try await Measured()
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.command == nil && panel.panel.frame == rootFrame)
  panel.release()
  #expect(await eventually { model.body == "# First page" })
  await panel.controller.renderer.settled()
  let measured = PaletteLayout.panelHeight(
    card: model.cardHeight(answer: panel.controller.renderer.height, cap: panel.controller.renderer.cap))
  // The root once more, unchanged, then the page at its measured height: no frame in between.
  #expect(panel.shown.map(\.screen) == ["root", "extension:page"])
  #expect(panel.shown.map(\.frame.height) == [rootFrame.height, measured])
  #expect(panel.shown.allSatisfy { !$0.busy })
  // The width and the top edge never move.
  let frames = panel.panel.frames
  #expect(Set(frames.map(\.width)) == [rootFrame.width] && Set(frames.map(\.maxY)) == [rootFrame.maxY])
  #expect(frames.last?.height == measured)
  #expect(try logged(panel.root, "page").count == 1)
  await panel.finish()
}

@MainActor @Test func theDeadlineShowsRunningThenTheMeasuredPage() async throws {
  let panel = try await Measured()
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.command == nil)
  model.passDeadline()
  // The deadline: the command, busy, with its one row, at the list's height.
  let running = PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer)
  #expect(panel.shown.last?.screen == "extension:page" && panel.shown.last?.busy == true)
  #expect(panel.shown.last?.body == nil && panel.panel.frame.height == running)
  panel.release()
  #expect(await eventually { model.body == "# First page" })
  await panel.controller.renderer.settled()
  let measured = PaletteLayout.panelHeight(
    card: model.cardHeight(answer: panel.controller.renderer.height, cap: panel.controller.renderer.cap))
  #expect(panel.shown.map(\.screen) == ["root", "extension:page", "extension:page"])
  #expect(panel.shown.map(\.frame.height) == [rootFrame.height, running, measured])
  let frames = panel.panel.frames
  #expect(Set(frames.map(\.width)) == [rootFrame.width] && Set(frames.map(\.maxY)) == [rootFrame.maxY])
  #expect(try logged(panel.root, "page").count == 1)
  await panel.finish()
}

@MainActor @Test func aMeasurementThatEndsAfterEscapeChangesNothing() async throws {
  let panel = try await Measured()
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.escape())
  let drawn = panel.shown.count
  panel.release()
  try await Task.sleep(for: .milliseconds(200))
  #expect(model.command == nil && model.body == nil && panel.shown.count == drawn)
  #expect(panel.panel.frame == rootFrame)
  await panel.finish()
}

@MainActor @Test func aLateErrorOrCloseOfAnEntryCalledOffByEscapeChangesNothing() async throws {
  for answer in ["{broken", #"{"close":true}"#] {
    let (model, _, root) = try await transitions(answer: answer)
    defer { try? FileManager.default.removeItem(at: root) }
    var closed = 0
    model.onClose = { closed += 1 }
    model.arrivalDeadline = .seconds(60)
    model.go(Address(id: "slow"), submitted: true)
    #expect(await eventually { (try? logged(root).count) == 1 })
    #expect(model.escape())
    try release(root)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.command == nil && closed == 0 && model.input == "a" && model.results.count > 8)
    await model.finish()
  }
}

@MainActor @Test func aRepeatedReturnDuringAnEntryEntersAgainFromTheScreenShown() async throws {
  let (model, apps, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = apps
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "slow"
  await model.settled()
  #expect(model.selected?.row.title == "slow")
  model.arrivalDeadline = .seconds(60)
  controller.run()
  #expect(await eventually { (try? logged(root).count) == 1 })
  // Recorded as it is: the root is still what shows, so Return runs its selected row again, and the
  // second entry replaces the first.
  #expect(model.command == nil && model.selected?.row.title == "slow")
  controller.run()
  #expect(await eventually { (try? logged(root).count) == 2 })
  #expect(try logged(root).allSatisfy { $0.submitted && $0.input.isEmpty })
  try release(root)
  await model.settled()
  #expect(model.command?.id == "extension:slow" && model.results.map(\.row.title) == ["Finished"])
  #expect(try logged(root).count == 2)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aQueuedReturnSendsOneRequestAcrossTheBatchesItWaitsFor() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  var batches = 0
  let draw = model.onResultsChange
  model.onResultsChange = {
    draw?()
    if model.command == nil { batches += 1 }
  }
  model.input = "> B"
  controller.run()
  #expect(model.returnQueued)
  // The held pattern lets the list compose without it first: Return keeps waiting.
  #expect(await eventually { batches >= 1 })
  #expect(model.returnQueued && model.command == nil)
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.command != nil })
  await model.settled()
  let submitted = try logged(root, "echo").filter(\.submitted)
  #expect(submitted.count == 1 && submitted[0].input == "> B" && !model.returnQueued)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysThroughTheActionPanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate", fields: ["arguments": [["name": "hours"], ["name": "minutes"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.input = "caffeinate"
  await model.settled()
  #expect(model.selected?.row.id == "command" && model.declaredArguments.count == 2)
  model.setArgument("hours", to: "2")
  model.focusedArgument = "hours"
  model.toggleActions()
  #expect(model.actionsTitle == "caffeinate" && model.declaredArguments.isEmpty)
  #expect(model.escape())
  #expect(model.argumentValues == ["hours": "2"] && model.selected?.row.id == "command")
  // Return on the row itself enters with the draft; ⌘K runs the row's action as it was captured.
  guard case .run(let entered)? = model.returnAction?.kind else { throw CancellationError() }
  #expect(entered.arguments == ["hours": "2"])
  model.toggleActions()
  let picked = try #require(model.pick())
  #expect(picked.from?.row.id == "command" && model.actionsTitle == nil)
  guard case .run(let captured) = picked.action.kind else { throw CancellationError() }
  #expect(captured.arguments == nil && model.argumentValues == ["hours": "2"])
  await model.finish()
}

@MainActor @Test func editingASubmitCommandInsideADetailLeavesTheDetailsTarget() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(body: "<row title=\"Notes\" copy=\"note\">Additional details</row>")
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "report", script: "cat >/dev/null\nprintf '%s' '\(json)'",
    fields: ["submit": true, "arguments": [["name": "format"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.go(Address(id: "report"), submitted: true)
  await model.settled()
  model.move(1)
  #expect(model.activateReturn() && model.inDetail)
  // Typing, then filling a slot, in the detail: Return sends the edited request, not the detail's Copy.
  model.move(1)
  #expect(model.returnAction?.kind == .copy("note"))
  model.editInput("updated")
  #expect(model.inDetail && model.selection == nil && model.selected?.row.id == "submit")
  model.move(1)
  #expect(model.returnAction?.kind == .copy("note"))
  model.setArgument("format", to: "json")
  #expect(model.inDetail && model.selection == nil && model.selected?.row.id == "submit")
  // Sending it replaces the page: the fresh one starts with nothing selected.
  #expect(model.activateReturn())
  await model.settled()
  #expect(!model.inDetail && model.selection == nil && model.selected?.row.id == "submit")
  await model.finish()
}

/// A page with a long body, targets and a detail inside a detail, shown in an offscreen panel.
@MainActor private func scrolledPage() async throws -> (LauncherModel, PaletteController, URL) {
  let root = try scratch()
  let lines = (0..<60).map { "Line \($0)" }.joined(separator: "\n\n")
  let view = ProviderView(
    body:
      "# Report\n\(lines)\n<row title=\"Notes\" copy=\"n\">\(lines)\n<row title=\"Deeper\" copy=\"d\">\(lines)</row></row>\n<row title=\"Owner\" copy=\"o\"/>"
  )
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(root, name: "report", script: "cat >/dev/null\nprintf '%s' '\(json)'")
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.go(Address(id: "report"), submitted: true)
  await model.settled()
  await controller.renderer.settled()
  return (model, controller, root)
}

/// The page's scroll position once the selection's paint, which scrolls a target into view, is done.
@MainActor private func scrollY(_ controller: PaletteController) async throws -> Double {
  await controller.renderer.settled()
  var last = -1.0
  while true {
    try await Task.sleep(for: .milliseconds(100))
    let y = try #require(
      try await controller.renderer.page?.callJavaScript("return scrollY", contentWorld: .defaultClient)
        as? Double)
    if y == last { return y }
    last = y
  }
}
@MainActor private func scroll(_ controller: PaletteController, to y: Double) async throws {
  _ = try await controller.renderer.page?.callJavaScript("scrollTo(0, \(y))", contentWorld: .defaultClient)
}

@MainActor @Test func theActionPanelAndNestedDetailsKeepThePagesScrollAndSelection() async throws {
  let (model, controller, root) = try await scrolledPage()
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(model.results.map(\.row.title) == ["Notes", "Owner"])
  // The selected target is scrolled into view, then the page a little further.
  model.move(1)
  #expect(model.selectedTarget == "#0")
  let page = try await scrollY(controller) + 40
  try await scroll(controller, to: page)
  #expect(try await scrollY(controller) == page)
  // ⌘K and back: the page stays mounted where it was. Recorded as it is: unpainting the selected
  // target under the panel moves the page by a few points, and Escape keeps that position.
  model.toggleActions()
  let under = try await scrollY(controller)
  #expect(model.selectedTarget == nil && abs(under - page) <= 8)
  #expect(model.escape())
  #expect(try await scrollY(controller) == under && model.selectedTarget == "#0")
  // A detail, a detail inside it, and back twice: each page where it was, with its target selected.
  #expect(model.activateReturn())
  #expect(try await scrollY(controller) == 0 && model.inDetail)
  model.move(1)
  #expect(model.selected?.row.title == "Deeper")
  let detail = try await scrollY(controller) + 40
  try await scroll(controller, to: detail)
  #expect(model.activateReturn())
  #expect(try await scrollY(controller) == 0)
  #expect(model.escape())
  #expect(try await scrollY(controller) == detail && model.selected?.row.title == "Deeper")
  #expect(model.escape())
  #expect(try await scrollY(controller) == under && !model.inDetail && model.selectedTarget == "#0")
  controller.hide()
  await model.finish()
}

@MainActor @Test func aPermissionArrivingUnderTheActionPanelTakesTheNextKey() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.send("What is on today?")
  #expect(await eventually { fake.running })
  fake.text("Today.\n<row title=\"Tue\" copy=\"tue\"/>")
  #expect(await eventually { model.results.count == 1 })
  model.move(1)
  #expect(controller.panel.route(voiceKey(40, "k", .command)) && model.actionsTitle == "Tue")
  fake.ask()
  #expect(model.actionsTitle == nil)
  // Return is no decision; ⌘↩ allows, Escape would deny.
  #expect(controller.panel.route(voiceKey(36, "\r")))
  #expect(fake.decisions.isEmpty && model.agent.permissions.count == 1)
  #expect(controller.panel.route(voiceKey(36, "\r", .command)))
  #expect(fake.decisions.map(\.allow) == [true] && model.agent.permissions.isEmpty)
  fake.end()
  controller.hide()
  await model.finish()
}

/// Composes `marked` at the end of the field's text, as an input method does: AppKit keeps it in the field
/// editor, and the field's delegate hears of it only once it is committed (`commit`).
@MainActor private func compose(_ marked: String, in field: NSTextField) throws -> NSTextView {
  let editor = try #require(field.currentEditor() as? NSTextView)
  editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
  editor.setMarkedText(
    marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: 0))
  return editor
}
@MainActor private func commit(_ text: String, in editor: NSTextView) {
  editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
}
/// Lets SwiftUI apply the model to the fields.
@MainActor private func update(_ controller: PaletteController) async throws {
  try await Task.sleep(for: .milliseconds(50))
  controller.panel.contentView?.layoutSubtreeIfNeeded()
}
@MainActor private func fields(in view: NSView) -> [FocusReportingField] {
  (view as? FocusReportingField).map { [$0] } ?? view.subviews.flatMap(fields)
}

@MainActor @Test func aCompositionInTheActionPanelsFieldBecomesTheInputWhenCommitted() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "settings"
  await model.settled()
  model.toggleActions()
  try await update(controller)
  let field = try #require(controller.panel.input)
  #expect(model.actionsTitle == "Settings" && field.stringValue.isEmpty)
  let editor = try compose("か", in: field)
  try await update(controller)
  #expect(model.actionsTitle == "Settings" && model.input == "settings")
  #expect(editor.hasMarkedText() && field.stringValue == "か")
  // Committed, it closes the panel and is the whole input; the field is not written again.
  commit("か", in: editor)
  try await update(controller)
  #expect(model.actionsTitle == nil && model.input == "か" && field.stringValue == "か")
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionDuringAnEntryIsAddedWhenCommittedAndEndsAtTheDeadline() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  await model.settled()
  model.arrivalDeadline = .seconds(60)
  model.go(Address(id: "slow"), submitted: true)
  try await update(controller)
  let field = try #require(controller.panel.input)
  var editor = try compose("か", in: field)
  try await update(controller)
  #expect(model.command == nil && model.input == "a" && editor.hasMarkedText() && field.stringValue == "aか")
  // Committed, what was added to the old input is the new one's, and the field is rewritten to it.
  commit("か", in: editor)
  try await update(controller)
  #expect(model.command?.id == "extension:slow" && model.input == "か" && field.stringValue == "か")
  // A composition still open when the deadline shows the command.
  _ = model.escape()
  model.dismiss()
  controller.show(orderFront: false, listen: false)
  model.input = "a"
  await model.settled()
  model.arrivalDeadline = .seconds(60)
  model.go(Address(id: "slow"), submitted: true)
  try await update(controller)
  editor = try compose("か", in: field)
  model.passDeadline()
  #expect(model.command != nil)
  try await update(controller)
  // Recorded as it is: the field is written to the new, empty input, which commits the composition
  // with the old input before it, and that is typed into the command.
  #expect(model.input == "aか" && field.stringValue == "aか" && !editor.hasMarkedText())
  #expect(await eventually { (try? logged(root).contains { $0.input == "aか" && !$0.submitted }) == true })
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionInASlotIsItsValueWhenCommitted() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "note", fields: ["arguments": [["name": "title"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.input = "note"
  await model.settled()
  model.focusedArgument = "title"
  try await update(controller)
  let content = try #require(controller.panel.contentView)
  let slot = try #require(fields(in: content).first { $0 !== controller.panel.input })
  #expect(controller.panel.firstResponder === slot.currentEditor())
  let editor = try compose("か", in: slot)
  try await update(controller)
  #expect(model.argumentValues.isEmpty && editor.hasMarkedText() && slot.stringValue == "か")
  commit("か", in: editor)
  try await update(controller)
  #expect(model.argumentValues == ["title": "か"] && model.input == "note" && slot.stringValue == "か")
  controller.hide()
  await model.finish()
}

@MainActor @Test func anEmptyQuestionDuringAnEntryCallsItOffWithItsRequest() async throws {
  let (model, _, root) = try await transitions(answer: #"{"close":true}"#)
  defer { try? FileManager.default.removeItem(at: root) }
  var closed = 0
  model.onClose = { closed += 1 }
  model.go(Address(id: "page"), submitted: true)
  await model.settled()
  #expect(model.command?.id == "extension:page" && model.body == "# First page")
  // A page on its way over the first one, and ⌘↩ with nothing typed while it is measured.
  model.arrivalDeadline = .seconds(60)
  var measuring: CheckedContinuation<Void, Never>?
  model.preparePage = { _, _ in await withCheckedContinuation { measuring = $0 } }
  model.go(Address(id: "other"), submitted: true)
  #expect(await eventually { measuring != nil })
  model.askAgent()
  #expect(model.agent.active && model.returnsOnEscape && model.command?.id == "extension:page")
  measuring?.resume()
  await model.settled()
  // The first command, exactly as it was under the question.
  #expect(model.escape())
  #expect(model.command?.id == "extension:page" && model.body == "# First page" && !model.agent.active)
  // A submitted close of an entry called off this way hides nothing.
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.askAgent()
  try release(root)
  try await Task.sleep(for: .milliseconds(200))
  #expect(closed == 0 && model.agent.active && model.returnsOnEscape)
  #expect(model.escape())
  #expect(model.command?.id == "extension:page" && model.body == "# First page")
  #expect(try logged(root, "page").count == 1 && logged(root, "other").count == 1)
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysUnderAnEmptyQuestion() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate", fields: ["arguments": [["name": "hours"], ["name": "minutes"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  await model.extensions.reload()
  model.refresh()
  await model.settled()
  let row = try #require(model.results.first { $0.provider == "extension:caffeinate" }?.id)
  model.select(row)
  model.setArgument("hours", to: "2")
  // The question has its own input, values and selection; Escape finds the root as it was.
  model.askAgent()
  #expect(model.agent.active && model.argumentValues.isEmpty && model.selection == nil)
  model.editInput("how long")
  #expect(model.escape())
  #expect(model.input.isEmpty && model.selection == row && model.argumentValues == ["hours": "2"])
  // Sending instead leaves the draft behind with the root.
  model.askAgent()
  model.editInput("how long")
  #expect(model.activateReturn() && model.agent.question == "how long")
  model.agent.cancel()
  #expect(await eventually { !model.agent.busy })
  #expect(model.escape())
  await model.settled()
  #expect(!model.agent.active && model.input.isEmpty && model.argumentValues.isEmpty)
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysUnderAnEmptyQuestionKeptWhileHidden() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "caffeinate", fields: ["arguments": [["name": "hours"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.refresh()
  await model.settled()
  let row = try #require(model.results.first { $0.provider == "extension:caffeinate" }?.id)
  model.select(row)
  model.setArgument("hours", to: "2")
  model.askAgent()
  model.editInput("how long")
  // Hidden and shown again, the question is kept, and Escape still finds the root as it was.
  model.dismiss()
  model.reopen()
  #expect(model.returnsOnEscape && model.input == "how long")
  #expect(model.escape())
  #expect(model.selection == row && model.argumentValues == ["hours": "2"])
  // Leaving the question for the root another way, by a link, starts the root over.
  model.askAgent()
  model.go(Address(input: ""))
  await model.settled()
  #expect(!model.agent.active && model.command == nil && model.argumentValues.isEmpty)
  model.select(row)
  model.setArgument("hours", to: "2")
  // Hiding the root itself drops them.
  model.dismiss()
  model.reopen()
  #expect(model.argumentValues.isEmpty)
  // So does the question expiring while hidden: the root starts over.
  model.select(row)
  model.setArgument("hours", to: "3")
  model.askAgent()
  model.dismiss()
  model.reopen(now: Date().addingTimeInterval(60 * 60))
  #expect(!model.agent.active && model.argumentValues.isEmpty)
  await model.finish()
}

@MainActor @Test func aPermissionDeliveredWhileHiddenTakesTheKeysWhenShown() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.send("Update the weather extension")
  #expect(await eventually { fake.running })
  fake.text("Working on it.\n<row title=\"Tue\" copy=\"tue\"/>")
  #expect(await eventually { model.results.count == 1 })
  model.move(1)
  controller.hide()
  fake.ask()
  #expect(model.agent.permissions.count == 1 && fake.decisions.isEmpty)
  controller.show(orderFront: false, listen: false)
  // The card is what shows: ⌘K waits, Return decides nothing, ⌘↩ allows.
  #expect(model.agent.active && model.agent.permissions.count == 1 && model.actionsTitle == nil)
  #expect(controller.panel.route(voiceKey(40, "k", .command)) && model.actionsTitle == nil)
  #expect(controller.panel.route(voiceKey(36, "\r")) && fake.decisions.isEmpty)
  #expect(controller.panel.route(voiceKey(36, "\r", .command)))
  #expect(fake.decisions.map(\.allow) == [true] && model.agent.permissions.isEmpty && model.agent.busy)
  fake.end()
  #expect(await eventually { !model.agent.busy })
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCoveredCommandFinishingAfterTheQuestionWasLeftShowsItsResult() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.arrivalDeadline = .milliseconds(1)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.command?.busy == true })
  model.askAgent()
  model.editInput("is it slow")
  // Escape before sending: the command, still running, with its own empty input.
  #expect(model.escape())
  #expect(!model.agent.active && model.command?.busy == true && model.input.isEmpty)
  let trace = Trace(model)
  try release(root)
  await model.settled()
  #expect(trace.screens == ["extension:slow"])
  #expect(
    trace.frames.last
      == .init(
        screen: "extension:slow", input: "", rows: ["Finished"], selection: "Finished", busy: false,
        height: one))
  #expect(try logged(root).count == 1)
  await model.finish()
}

// The gate before the agent moves onto the stack with the other screens: Back after a conversation traced
// from the Escape itself, the context an empty question captured, the deadline, the renderer and the
// provider released in each order, late deliveries after a replacement or hiding, a rerun in place and a
// hotkey's view adopted over an entry.

private let twoRows =
  #"{"items":[{"id":"one","title":"First","actions":[]},{"id":"two","title":"Second","actions":[]}]}"#
private let listHeight = PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(2) + PaletteLayout.footer)

@MainActor @Test func aRefreshedBackShowsTheConversationUntilTheCommandAnswersThenItsFirstRow() async throws {
  let panel = try await Measured(answer: twoRows)
  let model = panel.model
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.arrivalDeadline = .seconds(60)
  try release(panel.root)
  model.go(Address(id: "slow"), submitted: true)
  await model.settled()
  model.move(1)
  #expect(model.selected?.row.title == "Second")
  model.askAgent()
  model.editInput("why")
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  fake.text("Because.")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.editInput("and then")
  try FileManager.default.removeItem(at: panel.root.appending(path: "extensions/slow/release"))
  let drawn = panel.shown.count
  let frames = panel.panel.frames.count
  let top = panel.panel.frame.maxY
  // Escape stages the way back and a second one waits for it: the conversation stays as it is.
  #expect(model.escape())
  #expect(model.escape())
  #expect(await eventually { (try? logged(panel.root).count) == 2 })
  #expect(model.agent.active && model.input == "and then" && model.selection == nil)
  #expect(model.command?.busy == false && panel.panel.frames.count == frames)
  #expect(panel.shown.dropFirst(drawn).allSatisfy { $0.screen == "agent" && $0.input == "and then" })
  try release(panel.root)
  #expect(await eventually { !model.agent.active })
  await model.settled()
  // The command with a blank input, its first row, at the list's height, the top edge where it was.
  let last = try #require(panel.shown.last)
  #expect(last.screen == "extension:slow" && last.input.isEmpty && last.selection == "First" && !last.busy)
  #expect(panel.panel.frame.height == listHeight && panel.panel.frame.maxY == top)
  #expect(panel.panel.frames.dropFirst(frames).map(\.height) == [listHeight])
  let sent = try logged(panel.root)
  #expect(sent.count == 2 && sent[0].submitted && !sent[1].submitted && sent[1].input.isEmpty)
  await panel.finish()
}

@MainActor @Test func anEmptyQuestionSendsWhatWasShownWhenItOpened() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Each answer is numbered; a request waits while `hold` exists.
  _ = try extensionFolder(
    root, name: "counter",
    script: """
      import json,os,sys,time
      request = json.load(sys.stdin)
      open('log.jsonl', 'a').write(json.dumps(request) + '\\n')
      count = len(open('log.jsonl').readlines())
      while os.path.exists('hold'): time.sleep(0.01)
      print(json.dumps({'items':[{'id':'shown','title':'View %d' % count,'actions':[]}]}))
      """, fields: ["command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  await model.extensions.reload()
  model.go(Address(id: "counter"), submitted: true)
  await model.settled()
  #expect(model.results.map(\.row.title) == ["View 1"])
  // A rerun on its way, held, when ⌘↩ with nothing typed opens the question over it.
  let hold = root.appending(path: "extensions/counter/hold")
  try Data().write(to: hold)
  model.refresh()
  #expect(await eventually(within: .seconds(3)) { (try? logged(root, "counter").count) == 2 })
  model.askAgent()
  #expect(model.agent.active && model.returnsOnEscape && model.command?.busy == true)
  // The covered rerun finishes under the question, before it is sent.
  try FileManager.default.removeItem(at: hold)
  #expect(await eventually(within: .seconds(3)) { model.command?.busy == false })
  #expect(model.command?.shown.view.items.map(\.title) == ["View 2"])
  model.editInput("what is this")
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  // The question tells the agent what showed when it was opened.
  let prompt = try #require(fake.prompts.first?.text)
  #expect(prompt.contains("View 1") && !prompt.contains("View 2") && model.agent.source == "counter")
  #expect(try logged(root, "counter").count == 2)
  fake.end()
  await model.finish()
}

@MainActor @Test func aQuestionPrefilledByAnAddressGoesBackToTheRoot() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.go(Address(id: "notes"), submitted: true)
  #expect(model.command?.id == "extension:notes")
  let trace = Trace(model)
  model.go(Address(extensionName: "agent", input: "Why?"), from: "extension:notes")
  #expect(model.agent.active && model.command == nil && model.input == "Why?" && !model.returnsOnEscape)
  #expect(model.escape())
  await model.settled()
  #expect(!model.agent.active && model.command == nil && model.input.isEmpty)
  #expect(
    trace.screens == ["agent", "root"] && trace.frames.last?.selection == model.results.first?.row.title)
  await model.finish()
}

private let page = String(
  decoding: try! JSONEncoder().encode(ProviderView(body: "# Late page")), as: UTF8.self)

@MainActor @Test func theDeadlineThenTheAnswerShowsRunningThenThePageRenderedWhereItShows() async throws {
  let panel = try await Measured(answer: page)
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(panel.root).count) == 1 })
  model.passDeadline()
  let running = PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer)
  #expect(model.command?.busy == true && panel.panel.frame.height == running)
  try release(panel.root)
  #expect(await eventually { model.body == "# Late page" })
  await panel.controller.renderer.settled()
  // Shown already, the page is rendered where it shows rather than measured first.
  #expect(panel.measuring == 0)
  let measured = PaletteLayout.panelHeight(
    card: model.cardHeight(answer: panel.controller.renderer.height, cap: panel.controller.renderer.cap))
  #expect(panel.shown.map(\.screen) == ["root", "extension:slow", "extension:slow"])
  #expect(panel.shown.map(\.busy) == [false, true, false])
  #expect(panel.panel.frame.height == measured)
  let frames = panel.panel.frames
  #expect(Set(frames.map(\.width)) == [rootFrame.width] && Set(frames.map(\.maxY)) == [rootFrame.maxY])
  #expect(try logged(panel.root).count == 1)
  await panel.finish()
}

@MainActor @Test func theAnswerAndItsMeasurementBeforeTheDeadlineLeaveTheDeadlineNothingToDo() async throws {
  let panel = try await Measured(answer: page)
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  try release(panel.root)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.body == "# Late page" })
  let drawn = panel.shown.count
  let frames = panel.panel.frames
  model.passDeadline()
  #expect(panel.shown.count == drawn && panel.panel.frames == frames)
  #expect(panel.shown.map(\.screen) == ["root", "extension:slow"] && panel.shown.allSatisfy { !$0.busy })
  await panel.finish()
}

@MainActor @Test func pageToPageKeepsTheOutgoingPageAndFrameUntilTheIncomingOneIsMeasured() async throws {
  let panel = try await Measured()
  let model = panel.model
  model.arrivalDeadline = .seconds(60)
  model.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.body == "# First page" })
  await panel.controller.renderer.settled()
  let first = panel.panel.frame
  let drawn = panel.shown.count
  let frames = panel.panel.frames.count
  model.go(Address(id: "other"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.command?.id == "extension:page" && model.body == "# First page")
  #expect(panel.panel.frame == first && panel.panel.frames.count == frames)
  panel.release()
  #expect(await eventually { model.body == "# Second page" })
  await panel.controller.renderer.settled()
  #expect(panel.shown.dropFirst(drawn).map(\.screen).last == "extension:other")
  #expect(panel.shown.allSatisfy { !$0.busy })
  // Both one-line pages measure the same, so the frame never moves.
  #expect(panel.panel.frame == first && panel.panel.frames.count == frames)
  #expect(try logged(panel.root, "page").count == 1 && logged(panel.root, "other").count == 1)
  await panel.finish()
}

@MainActor @Test func aMeasurementEndingAfterAReplacementOrHidingChangesNothing() async throws {
  for replaced in [true, false] {
    let panel = try await Measured()
    let model = panel.model
    model.arrivalDeadline = .seconds(60)
    model.go(Address(id: "page"), submitted: true)
    #expect(await eventually { panel.measuring == 1 })
    if replaced {
      model.go(Address(id: "notes"), submitted: true)
      #expect(model.command?.id == "extension:notes")
    } else {
      panel.controller.hide()
    }
    // Hiding composes the empty root; the measurement is still held.
    await model.root.settled()
    let turn = model.pageTurn
    let drawn = panel.shown.count
    let frame = panel.panel.frame
    panel.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.command?.id == (replaced ? "extension:notes" : nil) && model.body == nil)
    #expect(model.pageTurn == turn && panel.shown.count == drawn && panel.panel.frame == frame)
    #expect(try logged(panel.root, "page").count == 1)
    await panel.finish()
  }
}

/// Answers once `release` exists, then marks that it printed, so a test can hold the main actor until
/// the answer is read and call the request off only then: the answer arrives after the call-off.
private func printing(_ answer: String) -> String {
  "cat >> log.jsonl\necho >> log.jsonl\nwhile [ ! -e release ]; do sleep 0.01; done\nprintf '%s' '\(answer)'\ntouch printed"
}

@MainActor private func blockUntilPrinted(_ root: URL, _ name: String) {
  let printed = root.appending(path: "extensions/\(name)/printed")
  let start = Date()
  while !FileManager.default.fileExists(atPath: printed.path), Date().timeIntervalSince(start) < 5 {
    Thread.sleep(forTimeInterval: 0.01)
  }
  // The process has printed and exits; its output is read off the main actor meanwhile.
  Thread.sleep(forTimeInterval: 0.3)
}

@MainActor @Test func anAnswerArrivingAfterItsEntryWasReplacedOrHiddenChangesNothing() async throws {
  for answer in ["{broken", #"{"close":true}"#] {
    for replaced in [true, false] {
      let (model, _, root) = try await transitions()
      defer { try? FileManager.default.removeItem(at: root) }
      _ = try extensionFolder(root, name: "late", script: printing(answer))
      await model.extensions.reload()
      var closed = 0
      model.onClose = { closed += 1 }
      model.arrivalDeadline = .seconds(60)
      model.go(Address(id: "late"), submitted: true)
      #expect(await eventually { (try? logged(root, "late").count) == 1 })
      try release(root, "late")
      blockUntilPrinted(root, "late")
      if replaced { model.go(Address(id: "notes"), submitted: true) } else { model.dismiss() }
      let turn = model.command?.turn
      await model.settled()
      try await Task.sleep(for: .milliseconds(100))
      #expect(closed == 0 && model.command?.id == (replaced ? "extension:notes" : nil), "\(answer)")
      #expect(model.command?.problem == nil && model.command?.turn == turn)
      #expect(try logged(root, "late").count == 1)
      await model.finish()
    }
  }
}

@MainActor @Test func aRelativeAddressRerunsTheSameCommandInPlace() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(items: [
    Row(id: "next", title: "Next", actions: [.run(Address(input: "page 2"))])
  ])
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "pager", script: "cat >> log.jsonl\necho >> log.jsonl\nprintf '%s' '\(json)'")
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.go(Address(id: "pager"), submitted: true)
  await model.settled()
  let trace = Trace(model)
  #expect(model.activateReturn())
  // No switch: the same command, its rows kept while its request runs, then its answer.
  #expect(model.command?.id == "extension:pager" && model.input == "page 2" && model.command?.busy == true)
  #expect(model.results.map(\.row.title) == ["Next"])
  await model.settled()
  #expect(trace.screens == ["extension:pager"] && trace.frames.first?.busy == true)
  #expect(trace.frames.last?.busy == false && trace.frames.last?.selection == "Next")
  let sent = try logged(root, "pager")
  #expect(sent.count == 2 && sent[1].submitted && sent[1].input == "page 2")
  await model.finish()
}

@MainActor @Test func aHotkeysViewIsAdoptedOverAnEntryOnItsWay() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "mover",
    script: printing(#"{"items":[{"id":"moved","title":"Moved","actions":[]}]}"#),
    fields: [
      "items": [
        ["id": "left", "title": "Left half", "actions": [["type": "run", "arguments": ["to": "left"]]]]
      ]
    ])
  await model.extensions.reload()
  var shown = 0
  let press = Task { await model.press(HotkeyTarget(target: "extension:mover", item: "left")) { shown += 1 } }
  #expect(await eventually { (try? logged(root, "mover").count) == 1 })
  // An entry on its way when the hotkey's run answers.
  model.arrivalDeadline = .seconds(60)
  model.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  try release(root, "mover")
  await press.value
  #expect(shown == 1 && model.command?.id == "extension:mover" && model.command?.busy == false)
  #expect(model.results.map(\.row.title) == ["Moved"] && model.input.isEmpty)
  // The entry's late answer changes nothing, and nothing ran twice.
  try release(root)
  try await Task.sleep(for: .milliseconds(100))
  await model.settled()
  #expect(model.command?.id == "extension:mover" && model.results.map(\.row.title) == ["Moved"])
  #expect(try logged(root, "mover").count == 1 && logged(root).count == 1)
  await model.finish()
}
