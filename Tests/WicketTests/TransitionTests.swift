import AppKit
import Foundation
import Testing

@testable import WicketApp

// The transitions between screens as they are, recorded before the screens move to their own owners:
// what the panel would draw at each publish, which requests ran, and which effects happened. Races are
// driven by gates (a file an extension waits for, apps that answer when released), never by timing alone.

/// Twelve apps, held back on request until released, so the root can be kept waiting.
@MainActor private final class GatedApps {
  var held = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func search(_ input: String) async -> SearchIndex {
    if held { await withCheckedContinuation { waiting.append($0) } }
    return SearchIndex((0..<12).map { row("App \($0)") })
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
  let surface = RecordingSurface()
  init(_ model: LauncherModel) {
    model.navigator.surface = surface
    surface.onDraw = { [weak self, weak model] in
      guard let self, let model else { return }
      frames.append(
        Frame(
          screen: model.agent.active ? "agent" : model.navigator.command?.id ?? "root",
          input: model.navigator.input,
          rows: model.navigator.results.map(\.row.title), selection: model.navigator.selected?.row.title,
          body: model.navigator.body,
          busy: model.navigator.command?.busy == true,
          height: PaletteLayout.cardHeight(
            model.navigator.presentation, answer: PaletteLayout.answerMin, cap: PaletteLayout.answerMax)))
    }
  }
  /// The screens in the order they were drawn, each once per visit.
  var screens: [String] {
    frames.map(\.screen).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
  }
}

private let full = PaletteLayout.rowsHeight(8) + PaletteLayout.footer
private let one = PaletteLayout.rowsHeight(1) + PaletteLayout.footer

@MainActor @Test(arguments: [false, true])
func anUpdateNoticeShowsAtTheEmptyRootAndReturnOpensTheUpdater(compact: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let history = UsageHistory(url: root.appending(path: "usage.json"))
  let apps = GatedApps()
  var checks = 0
  let model = LauncherModel(
    apps: apps.search, history: history, folder: root, bundled: nil, availableUpdate: { "0.8.0" },
    checkForUpdates: { checks += 1 })
  model.store.update { $0.resultsOnlyWhenTyping = compact }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  let navigator = model.navigator
  let surface = RecordingSurface(wrapping: controller)
  navigator.surface = surface
  controller.show(orderFront: false, listen: false)
  await navigator.settled()

  let notice = try #require(surface.presentation.selected)
  #expect(notice.row.title == "Update Wicket to 0.8.0")
  #expect(surface.presentation.showsCard && surface.presentation.rows.first == notice)
  #expect(navigator.hotkeyTarget(of: notice) == nil)
  if compact {
    #expect(surface.presentation.rows == [notice] && surface.presentation.sizedRows == 1)
    navigator.move(1)
    #expect(surface.presentation.rows.count > 1 && surface.presentation.rows.first == notice)
  } else {
    #expect(surface.presentation.rows.count > 1)
  }
  apps.held = true
  navigator.editInput("settings")
  #expect(!surface.presentation.rows.contains(notice))
  apps.release()
  await navigator.settled()
  navigator.editInput("")
  await navigator.settled()
  #expect(surface.presentation.selected == notice)
  #expect(navigator.returnPlan() == .run)
  navigator.run()
  #expect(surface.effects == [.hide, .checkForUpdates] && checks == 1 && !controller.isShown)
  #expect(history.store.entries.isEmpty)

  var ranked: [Result] = []
  model.root.search("", speaking: false) { ranked = $0.results }
  await model.root.settled()
  #expect(!ranked.isEmpty && !ranked.contains(notice))
  await controller.finish()
}

@MainActor @Test func anUpdateNoticeWaitsForNextOpenAndCanBeDismissedForTheSession() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  var availableUpdate: String?
  let model = LauncherModel(
    history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: nil,
    availableUpdate: { availableUpdate })
  model.store.update { $0.resultsOnlyWhenTyping = true }
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  model.reopen()
  navigator.refresh()
  let initial = surface.presentation.rows
  #expect(!surface.presentation.showsCard)

  availableUpdate = "0.8.0"
  navigator.refresh()
  #expect(surface.presentation.rows == initial && !surface.presentation.showsCard)
  navigator.dismiss()
  model.reopen()
  let notice = try #require(surface.presentation.selected)
  #expect(surface.presentation.rows == [notice] && surface.presentation.offersActions)
  navigator.toggleActions()
  #expect(surface.presentation.rows.map(\.row.title) == ["Show What's New", "Dismiss"])
  navigator.move(1)
  navigator.run()
  #expect(surface.effects.isEmpty)
  #expect(surface.presentation.rows == initial && !surface.presentation.showsCard)

  navigator.dismiss()
  model.reopen()
  navigator.refresh()
  #expect(!surface.presentation.showsCard && surface.presentation.rows == initial)
  #expect(availableUpdate == "0.8.0")
  await model.finish()
}

@MainActor @Test func aQueuedReturnCannotOpenAnUpdateNoticeItNeverSaw() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let apps = GatedApps()
  var availableUpdate: String?
  let model = LauncherModel(
    apps: apps.search, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil,
    availableUpdate: { availableUpdate })
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  model.reopen()
  navigator.refresh()
  navigator.editInput("app")
  await navigator.settled()
  apps.held = true
  navigator.editInput("")
  // Keep Return waiting on the new empty query as an unavailable first list would.
  navigator.run()

  availableUpdate = "0.8.0"
  model.reopen()
  apps.release()
  await navigator.settled()
  #expect(surface.presentation.selected?.row.title == "Update Wicket to 0.8.0")
  #expect(surface.effects.isEmpty)
  await model.finish()
}

@MainActor @Test func aHotkeySelectsItsRepairWhenTheInitialRootResultsArrive() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "broken", fields: ["contract": 0])
  let apps = GatedApps()
  apps.held = true
  let model = LauncherModel(
    apps: apps.search, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  model.store.update { $0.resultsOnlyWhenTyping = true }
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  surface.shown = false
  navigator.surface = surface
  #expect(navigator.results.isEmpty)

  model.press(HotkeyTarget(target: "extension:broken"))
  #expect(surface.presentation.footerMessage == "No extension named broken")
  apps.release()
  await navigator.settled()
  #expect(surface.presentation.showsCard)
  #expect(surface.presentation.selected?.row.id == "discovery-error")
  await model.finish()
}

@MainActor @Test func hiddenRootResultsKeepItsSearchAndReturnAndRevealsTheCard() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let initial = try extensionFolder(
    root, name: "initial",
    script: answering("Initial result").replacingOccurrences(
      of: "cat >/dev/null", with: "cat >> log.jsonl\necho >> log.jsonl"),
    fields: ["match": "^$"])
  let apps = GatedApps()
  let model = LauncherModel(
    apps: apps.search, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  try Data(#"{"resultsOnlyWhenTyping":true}"#.utf8).write(to: model.store.url)
  model.store.load()
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  model.reopen()
  navigator.refresh()
  await navigator.settled()

  #expect(!surface.presentation.showsCard)
  #expect(PaletteLayout.cardHeight(surface.presentation, answer: 80, cap: 500) == 0)
  #expect(surface.presentation.selected?.row.title == "Initial result")
  #expect(try requests(in: initial).last?.input == "")
  navigator.run()
  #expect(surface.effects.last == .run(.copy("Initial result"), from: surface.presentation.selected))

  navigator.move(1)
  #expect(surface.presentation.showsCard)
  #expect(surface.presentation.selected?.row.title == "App 0")
  navigator.dismiss()
  model.reopen()
  navigator.refresh()
  await navigator.settled()
  #expect(!surface.presentation.showsCard)

  apps.held = true
  navigator.editInput("app")
  #expect(model.root.isSearching && surface.presentation.showsCard)
  apps.release()
  await navigator.settled()
  navigator.editInput("")
  #expect(!surface.presentation.showsCard)
  await navigator.settled()
  #expect(!surface.presentation.showsCard && surface.presentation.selected?.row.title == "Initial result")
  await model.finish()
}

@MainActor @Test func hiddenRootResultsKeepProblemsInThePillAndReopensAKeptConversation() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  try Data(#"{"resultsOnlyWhenTyping":true}"#.utf8).write(to: model.store.url)
  model.store.load()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.refresh()
  #expect(!surface.presentation.showsCard)

  navigator.go(Address(id: "missing"))
  #expect(!surface.presentation.showsCard)
  #expect(surface.presentation.pillStatus == "No extension named missing")
  navigator.editInput("")
  #expect(!surface.presentation.showsCard && surface.presentation.pillStatus == nil)

  _ = try extensionFolder(root, name: "broken", script: "exit 1", fields: ["match": "^$"])
  await model.extensions.reload()
  await navigator.settled()
  #expect(!surface.presentation.showsCard)
  #expect(surface.presentation.pillStatus?.hasSuffix(" failed") == true)
  navigator.move(1)
  #expect(surface.presentation.showsCard && surface.presentation.pillStatus == nil)
  #expect(surface.presentation.rows.contains { $0.row.id == "error" })
  navigator.dismiss()
  try FileManager.default.removeItem(at: root.appending(path: "extensions/broken"))
  await model.extensions.reload()
  await navigator.settled()
  #expect(!surface.presentation.showsCard)

  try await finishTurn(model, "A question", "An answer")
  navigator.dismiss()
  model.reopen()
  #expect(navigator.input.isEmpty)
  #expect(navigator.presentation.showsCard && navigator.presentation.agent?.question == "A question")
  await model.finish()
}

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
    apps: apps.search, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  // The tests count frames; when the busy state draws is its own test's.
  model.navigator.busyDelay = .seconds(60)
  model.navigator.input = "a"
  await model.navigator.settled()
  #expect(model.navigator.results.count > 8 && model.navigator.sizedRows == 8)
  return (model, apps, root)
}

func release(_ root: URL, _ name: String = "slow") throws {
  try Data().write(to: root.appending(path: "extensions/\(name)/release"))
}
private func logged(_ root: URL, _ name: String = "slow") throws -> [ProviderRequest] {
  try requests(in: root.appending(path: "extensions/" + name))
}

@MainActor @Test func aSlowListShowsRunningAtTheDeadlineThenItsOutputInOneStep() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let trace = Trace(model)
  model.navigator.arrivalDeadline = .milliseconds(30)
  model.navigator.go(Address(id: "slow"), submitted: true)
  // Recorded as it is: starting the request draws the root once more, unchanged.
  let rootFrame = try #require(trace.frames.first)
  #expect(trace.frames.count == 1 && rootFrame.screen == "root" && rootFrame.input == "a")
  #expect(rootFrame.rows.count == 13 && rootFrame.selection == "App 0" && rootFrame.height == full)
  #expect(await eventually { model.navigator.command != nil })
  #expect(
    trace.frames == [
      rootFrame, .init(screen: "extension:slow", input: "", rows: [], busy: true, height: one),
    ])
  try release(root)
  await model.navigator.settled()
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
  model.navigator.arrivalDeadline = .seconds(60)
  var measuring: CheckedContinuation<Void, Never>?
  trace.surface.onPrepare = { _, _ in
    await withCheckedContinuation { measuring = $0 }
    return .unmeasured
  }
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { measuring != nil })
  #expect(model.navigator.command == nil)
  // The deadline shows the command, still busy and with no page, while the same render goes on.
  model.navigator.passDeadline()
  #expect(
    model.navigator.command?.busy == true && model.navigator.body == nil && model.navigator.results.isEmpty)
  measuring?.resume()
  #expect(await eventually { model.navigator.body == "# First page" })
  #expect(
    trace.frames.map { [$0.screen, $0.body ?? "-", "\($0.busy)"] } == [
      ["root", "-", "false"], ["extension:page", "-", "true"], ["extension:page", "# First page", "false"],
    ])
  #expect(try logged(root, "page").count == 1)
  await model.finish()
}

/// Running… and the spinner show only once a request has run for `busyDelay`: a quick answer replaces
/// the screen with no busy state drawn first, a slow one says it is running until it answers.
@MainActor @Test func theBusyStateShowsOnlyOnceARequestHasRunForItsDelay() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let surface = RecordingSurface()
  model.navigator.surface = surface
  var drawn: [(screen: String, busy: Bool)] = []
  surface.onDraw = {
    drawn.append((model.navigator.command?.id ?? "root", model.navigator.presentation.showsBusy))
  }
  model.navigator.arrivalDeadline = .zero
  model.navigator.busyDelay = .seconds(5)
  model.navigator.go(Address(id: "page"), submitted: true)
  await model.navigator.settled()
  #expect(model.navigator.body == "# First page" && drawn.allSatisfy { !$0.busy })
  model.navigator.busyDelay = .milliseconds(300)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { drawn.last?.screen == "extension:slow" })
  #expect(drawn.last?.busy == false && model.navigator.command?.busy == true)
  #expect(await eventually { drawn.last?.busy == true })
  try release(root)
  await model.navigator.settled()
  #expect(drawn.last?.busy == false && model.navigator.results.map(\.row.title) == ["Finished"])
  await model.finish()
}

/// The busy delay times the process alone: once it has answered, the delay passing while its page is
/// measured shows no busy state. (A process slower than the delay shows it already, as it should.)
@MainActor @Test func measuringAnAnsweredPageNeverStartsTheBusyState() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let surface = RecordingSurface()
  model.navigator.surface = surface
  var measuring: CheckedContinuation<Void, Never>?
  surface.onPrepare = { _, _ in
    await withCheckedContinuation { measuring = $0 }
    return .unmeasured
  }
  model.navigator.arrivalDeadline = .seconds(60)
  model.navigator.busyDelay = .milliseconds(300)
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { measuring != nil })
  model.navigator.passDeadline()
  let answered = model.navigator.showsBusy
  try await Task.sleep(for: .milliseconds(500))
  #expect(model.navigator.command?.busy == true && model.navigator.showsBusy == answered)
  measuring?.resume()
  await model.navigator.settled()
  #expect(model.navigator.body == "# First page" && !model.navigator.showsBusy)
  await model.finish()
}

@MainActor @Test func aLateAnswerOfALeftEntryChangesNothing() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(5)
  // Hidden while entering: the late answer shows nothing.
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.navigator.dismiss()
  try release(root)
  try await Task.sleep(for: .milliseconds(100))
  #expect(model.navigator.command == nil && model.navigator.input.isEmpty)
  // Replaced by another command: the late answer of the first is dropped.
  try FileManager.default.removeItem(at: root.appending(path: "extensions/slow/release"))
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 2 })
  model.navigator.go(Address(id: "notes"), submitted: true)
  #expect(model.navigator.command?.id == "extension:notes")
  try release(root)
  try await Task.sleep(for: .milliseconds(100))
  #expect(model.navigator.command?.id == "extension:notes" && model.navigator.command?.problem == nil)
  await model.finish()
}

@MainActor @Test func aSecondEscapeWhileGoingBackWaitsForTheRoot() async throws {
  let (model, apps, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.go(Address(id: "notes"), submitted: true)
  #expect(model.navigator.command?.id == "extension:notes" && model.navigator.sizedRows == 2)
  let trace = Trace(model)
  apps.held = true
  #expect(model.navigator.escape())
  #expect(model.navigator.escape())
  // Still the command, exactly as it was, and nothing was drawn.
  #expect(
    model.navigator.command?.id == "extension:notes"
      && model.navigator.results.map(\.row.title) == ["Groceries", "Ideas"])
  #expect(trace.frames.isEmpty)
  apps.release()
  await model.navigator.settled()
  #expect(model.navigator.command == nil && model.navigator.input.isEmpty && model.navigator.sizedRows == 8)
  #expect(trace.screens == ["root"] && trace.frames.allSatisfy { $0.height == full })
  await model.finish()
}

/// One renderer serves every page: a measurement that returns after another page took the renderer (a
/// list's detail on an arrow key) is measured again before the arriving page shows.
@MainActor @Test func anArrivingPageWaitsForAMeasurementOfItsOwnTurnAndShowsAtItsHeight() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(60)
  let surface = RecordingSurface()
  model.navigator.surface = surface
  var turns: [String] = []
  surface.onPrepare = { page, turn in
    turns.append(turn)
    // The first pass measured another page; the command is still not shown.
    if turns.count == 1 { return .superseded }
    #expect(model.navigator.command == nil && page.source == "# First page")
    return .measured(PageHeight(turn: turn, height: 300))
  }
  model.navigator.go(Address(id: "page"), submitted: true)
  await model.navigator.settled()
  #expect(turns.count == 2 && turns[0] == turns[1])
  #expect(model.navigator.command?.id == "extension:page" && model.navigator.body == "# First page")
  // Shown in one step with the height measured for it.
  #expect(surface.changes.last == .measured(PageHeight(turn: turns[0], height: 300)))
  #expect(surface.changes.dropLast().allSatisfy { $0 == .content })
  #expect(model.navigator.pageTurn == turns[0])
  #expect(try logged(root, "page").count == 1)
  await model.finish()
}

@MainActor @Test func aPageThatCannotBeMeasuredShowsAtOnce() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(60)
  let surface = RecordingSurface()
  model.navigator.surface = surface
  var prepared = 0
  surface.onPrepare = { _, _ in
    prepared += 1
    return .unmeasured
  }
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { model.navigator.body == "# First page" })
  // Measured once, not again until the deadline, and drawn as it is.
  #expect(prepared == 1 && surface.changes.allSatisfy { $0 == .content })
  await model.finish()
}

@MainActor @Test func pageToPageRendersTheIncomingPageWhileTheOutgoingOneShows() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(5)
  var measured: [(page: String, shown: String?)] = []
  let surface = RecordingSurface()
  model.navigator.surface = surface
  surface.onPrepare = { page, _ in
    measured.append((page.source, model.navigator.body))
    return .unmeasured
  }
  model.navigator.go(Address(id: "page"), submitted: true)
  await model.navigator.settled()
  model.navigator.go(Address(id: "other"), submitted: true)
  await model.navigator.settled()
  // The one renderer measures the second page while the first one is what the model shows.
  #expect(measured.map(\.page) == ["# First page", "# Second page"])
  #expect(measured.map(\.shown) == [nil, "# First page"])
  #expect(model.navigator.body == "# Second page")
  #expect(try logged(root, "page").count == 1 && logged(root, "other").count == 1)
  await model.finish()
}

@MainActor @Test func anImmediateDestinationRunsNoProcessAndEntersBeforeReturnReturns() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let trace = Trace(model)
  model.navigator.go(Address(id: "notes"), submitted: true)
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
  model.navigator.arrivalDeadline = .seconds(5)
  // An addition to the old input is what is typed into the new one.
  model.navigator.go(Address(id: "slow", input: "x"), submitted: true)
  model.navigator.editInput("ab")
  #expect(model.navigator.command?.id == "extension:slow" && model.navigator.input == "xb")
  // The entry's request is called off before it started, and the appended input runs once as typing.
  #expect(await eventually { (try? logged(root).count) == 1 })
  #expect(try logged(root).map { [$0.input, "\($0.submitted)"] } == [["xb", "false"]])
  model.navigator.dismiss()
  model.navigator.input = "a"
  await model.navigator.settled()
  // Anything else is the new input as a whole, run once as typing, never submitted.
  model.navigator.go(Address(id: "slow"), submitted: true)
  model.navigator.editInput("z")
  #expect(
    model.navigator.command?.id == "extension:slow" && model.navigator.input == "z"
      && model.navigator.command?.busy == true)
  #expect(await eventually { (try? logged(root).contains { $0.input == "z" }) == true })
  try release(root)
  await model.navigator.settled()
  let typed = try logged(root).filter { $0.input == "z" }
  #expect(typed.count == 1 && !typed[0].submitted && model.navigator.results.map(\.row.title) == ["Finished"])
  #expect(try logged(root).count == 2)
  await model.finish()
}

@MainActor @Test func speechDuringAnEntrySwitchesAndIsTheWholeInput() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let transcriber = FakeTranscriber()
  let voiced = LauncherModel(
    apps: GatedApps().search, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  let controller = PaletteController(model: voiced, panel: RoutingPanel(), transcriber: { transcriber })
  await model.finish()
  voiced.extensions.onCatalogChange = nil
  await voiced.extensions.reload()
  voiced.navigator.input = "a"
  await voiced.navigator.settled()
  controller.input.arm()
  transcriber.feeds[0].yield(.ready)
  #expect(await eventually { controller.input.voice?.state == .listening })
  voiced.navigator.arrivalDeadline = .seconds(5)
  voiced.navigator.go(Address(id: "slow"), submitted: true)
  transcriber.feeds[0].yield(.transcript("is it done"))
  #expect(await eventually { voiced.navigator.command != nil })
  #expect(
    voiced.navigator.command?.id == "extension:slow" && voiced.navigator.input == "is it done"
      && controller.input.voice?.active == true)
  // Speech waits its 350 ms before the rerun, which is never submitted.
  #expect(
    await eventually(within: .seconds(3)) {
      (try? logged(root).contains { $0.input == "is it done" }) == true
    })
  #expect(try logged(root).filter { $0.input == "is it done" }.allSatisfy { !$0.submitted })
  controller.input.stop(.edit)
  await controller.finish()
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
  model.navigator.go(Address(id: "links"), submitted: true)
  await model.navigator.settled()
  let turn = model.navigator.pageTurn
  model.navigator.move(1)
  model.navigator.move(1)
  #expect(model.navigator.selectedTarget == "#1")
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == "Blog" && model.navigator.selectedTarget == nil)
  #expect(model.navigator.escape())
  #expect(
    model.navigator.actionsTitle == nil && model.navigator.selectedTarget == "#1"
      && model.navigator.pageTurn == turn)
  // Two actions with one label: the second one chosen is the second one run, from the row it belongs to.
  model.navigator.move(1)
  model.navigator.toggleActions()
  #expect(model.navigator.results.map(\.row.title) == ["Open", "Open"])
  model.navigator.move(1)
  let picked = try #require(model.navigator.pick())
  #expect(picked.action.kind == .open(URL(string: "https://example.com/two")!))
  #expect(picked.from?.row.id == "twins" && model.navigator.actionsTitle == nil)
  // Typing into the panel's empty field closes it, and the text is the whole input.
  model.navigator.toggleActions()
  model.navigator.editInput("x")
  #expect(model.navigator.actionsTitle == nil && model.navigator.input == "x")
  // Cmd+Return closes it before asking.
  model.navigator.input = ""
  model.navigator.toggleActions()
  model.navigator.askAgent()
  #expect(model.navigator.actionsTitle == nil && model.agent.active && model.navigator.returnsOnEscape)
  await model.finish()
}

@MainActor @Test func cmdReturnOverARunningCommandKeepsItRunningAndEscapeRevealsItsResult() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .milliseconds(1)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.navigator.command?.busy == true })
  model.navigator.askAgent()
  #expect(model.agent.active && model.navigator.returnsOnEscape && model.navigator.askingAbout == "slow")
  try release(root)
  #expect(await eventually { model.navigator.command?.busy == false })
  // The result belongs to the command under the conversation.
  #expect(
    model.agent.active && model.navigator.results.isEmpty
      && model.navigator.command?.shown.view.items.count == 1)
  #expect(model.navigator.escape())
  #expect(
    !model.agent.active && model.navigator.results.map(\.row.title) == ["Finished"]
      && model.navigator.input.isEmpty)
  #expect(try logged(root).count == 1)
  await model.finish()
}

@MainActor @Test func aHiddenRunsFailureOverAKeptConversationSaysSoInOneLine() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "mover", script: "cat >/dev/null\necho nope >&2\nexit 1")
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.input = ""
  model.navigator.askAgent()
  // Hidden with the empty question kept: the panel shows it again, with what the run found in one line.
  surface.shown = false
  model.navigator.runHidden(Address(extensionName: "mover", hidden: true), from: nil)
  await model.navigator.settled()
  #expect(surface.shows == 1 && model.agent.active && model.navigator.returnsOnEscape)
  #expect(
    model.navigator.command == nil && model.navigator.actionProblem?.hasPrefix("mover: Extension") == true)
  await model.finish()
}

@MainActor @Test func sendingFromOverARunningCommandStopsItAndBackRunsItAgain() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.navigator.arrivalDeadline = .milliseconds(1)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.navigator.command?.busy == true })
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.navigator.askAgent()
  model.navigator.editInput("why so slow")
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  #expect(model.navigator.command?.busy == false && !model.navigator.returnsOnEscape)
  fake.text("Because.")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  try release(root)
  #expect(model.navigator.escape())
  await model.navigator.settled()
  // Back on the command with a blank input and a fresh request, not the old one revealed.
  #expect(
    !model.agent.active && model.navigator.command?.id == "extension:slow" && model.navigator.input.isEmpty)
  let sent = try logged(root)
  #expect(sent.count == 2 && sent[0].submitted && !sent[1].submitted)
  #expect(model.navigator.results.map(\.row.title) == ["Finished"])
  await model.finish()
}

/// A root pattern for `> text`, held on `release` for inputs with B, failing for inputs with F, answering
/// nothing for inputs with E.
@MainActor func staleReturn(
  transcriber: @escaping () -> any Transcriber = { FakeTranscriber() },
  openApplication: @escaping (URL, @escaping @MainActor (Error?) -> Void) -> Void = { _, _ in }
) async throws -> (LauncherModel, PaletteController, URL) {
  let root = try scratch()
  _ = try extensionFolder(
    root, name: "echo",
    script: """
      import json,sys,time,os
      request = json.load(sys.stdin)
      open('log.jsonl', 'a').write(json.dumps(request) + '\\n')
      text = request['input']
      if 'F' in text: sys.exit(1)
      if 'E' in text: print(json.dumps({'items':[]})); sys.exit(0)
      while 'B' in text and not os.path.exists('release'): time.sleep(0.01)
      print(json.dumps({'items':[{'id':'run','title':text,'actions':[{'type':'run','input':text}]}]}))
      """, fields: ["match": "^> ", "command": ["/usr/bin/python3", "main.sh"]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:echo")] }
  model.extensions.onCatalogChange = nil
  await model.extensions.reload()
  let controller = PaletteController(
    model: model, panel: RoutingPanel(), transcriber: transcriber, openApplication: openApplication)
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "> A"
  await model.navigator.settled()
  return (model, controller, root)
}

@MainActor @Test(arguments: ["edit", "pick", "hide"])
func aWaitingReturnIsCalledOffByAnEditAPickOrHiding(cancel: String) async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "> B"
  controller.run()
  #expect(model.navigator.returnPlan() == .wait)
  switch cancel {
  case "edit": model.navigator.editInput("> Bb")
  case "pick": model.navigator.select(model.navigator.results.first?.id)
  default:
    controller.hide()
    controller.show(orderFront: false, listen: false)
  }
  try release(root, "echo")
  await model.navigator.settled()
  #expect(model.navigator.command == nil && !model.agent.active)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aWaitingReturnRunsOnceAndNeverForAFailedPattern() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  // A failed pattern calls the waiting Return off: it never becomes Ask agent.
  model.navigator.input = "> F"
  controller.run()
  await model.navigator.settled()
  #expect(model.navigator.command == nil && !model.agent.active)
  #expect(model.navigator.results.contains { $0.row.id == "error" })
  // Replayed once, when the rows for what is typed arrive.
  model.navigator.input = "> B"
  controller.run()
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(
    model.navigator.command?.id == "extension:echo" && model.navigator.input == "> B")
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:echo" && !model.agent.active)
  controller.hide()
  await model.finish()
}

@MainActor private func liveReturnCommand(in root: URL) async throws -> (LauncherModel, RecordingSurface) {
  _ = try extensionFolder(
    root, name: "slow",
    script: """
      IFS= read -r request
      case "$request" in
        *'"input":"12*77"'*|*'"input":"broken"'*|*'"input":"replacement"'*|*'"input":"reranked"'*)
          touch rerunning
          while [ ! -e release ]; do sleep 0.01; done ;;
      esac
      id=result
      case "$request" in
        *'"input":"reranked"'*)
          printf '%s' '{"items":[{"id":"first","title":"reranked","actions":[{"type":"copy","text":"42"}]},'
          printf '%s' '{"id":"result","title":"Updated","actions":[{"type":"copy","text":"924"}]}]}'
          exit ;;
        *'"input":"replacement"'*) id=replacement; result=42 ;;
        *'"input":"broken"'*) echo 'Calculation failed' >&2; exit 1 ;;
        *'"input":"12*77"'*) result=924 ;;
        *) result=84 ;;
      esac
      printf '{"items":[{"id":"%s","title":"%s","actions":[{"type":"copy","text":"%s"}]}]}\n' "$id" "$result" "$result"
      """)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.go(Address(extensionName: "slow", input: "12*7"))
  await model.navigator.settled()
  return (model, surface)
}

@MainActor @Test func liveCommandReturnWaitsForTheCurrentInput() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await liveReturnCommand(in: root)
  let navigator = model.navigator
  navigator.editInput("12*77")
  let marker = root.appending(path: "extensions/slow/rerunning")
  #expect(await eventually { FileManager.default.fileExists(atPath: marker.path) })
  #expect(surface.presentation.selected?.row.title == "84")

  navigator.run()
  #expect(surface.effects.isEmpty)
  try release(root)
  await navigator.settled()
  #expect(surface.effects == [.run(.copy("924"), from: surface.presentation.selected)])
  await model.finish()
}

@MainActor @Test func liveCommandReturnRunsImmediatelyOnACurrentView() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await liveReturnCommand(in: root)
  model.navigator.run()
  #expect(surface.effects == [.run(.copy("84"), from: surface.presentation.selected)])
  await model.finish()
}

@MainActor @Test func liveCommandReturnIsDroppedWhenTheRerunFails() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await liveReturnCommand(in: root)
  let navigator = model.navigator
  navigator.editInput("broken")
  navigator.run()
  #expect(surface.effects.isEmpty)
  try release(root)
  await navigator.settled()
  #expect(navigator.returnPlan() != .wait)
  #expect(surface.presentation.problem?.contains("Calculation failed") == true)
  #expect(surface.effects.isEmpty && !model.agent.active)
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func liveActivationKeepsTheExplicitlyPickedItem(doubleClick: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await liveReturnCommand(in: root)
  let navigator = model.navigator
  let clicked = try #require(surface.presentation.selected)
  navigator.editInput("replacement")
  if doubleClick {
    navigator.runRow(clicked)
    #expect(surface.effects == [.run(.copy("84"), from: clicked)])
  } else {
    navigator.select(clicked.id)
    navigator.run()
    #expect(surface.effects.isEmpty)
  }

  try release(root)
  await navigator.settled()
  #expect(surface.presentation.selected?.row.id == "replacement")
  navigator.runRow(clicked)
  #expect(surface.effects == (doubleClick ? [.run(.copy("84"), from: clicked)] : []))
  await model.finish()
}

@MainActor @Test func liveReturnFollowsThePickedItemWhenItMoves() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await liveReturnCommand(in: root)
  let navigator = model.navigator
  let picked = try #require(surface.presentation.selected)
  navigator.editInput("reranked")
  navigator.select(picked.id)
  navigator.run()

  try release(root)
  await navigator.settled()
  #expect(surface.presentation.rows.first?.row.id == "first")
  #expect(surface.presentation.selected?.id == picked.id)
  #expect(surface.effects == [.run(.copy("924"), from: surface.presentation.selected)])
  await model.finish()
}

@MainActor @Test func aHiddenHotkeyRunsItsProgramOnceAndShowsAFailureOnce() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "mover",
    script:
      "cat >> log.jsonl\necho >> log.jsonl\nwhile [ ! -e release ]; do sleep 0.01; done\necho nope >&2\nexit 1",
    fields: [
      "items": [
        [
          "id": "left", "title": "Left half",
          "actions": [["type": "run", "action": "left", "hidden": true]],
        ]
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  model.press(HotkeyTarget(target: "extension:mover", item: "left"))
  #expect(await eventually { (try? logged(root, "mover").count) == 1 })
  #expect(surface.shows == 0 && model.navigator.command == nil)
  try release(root, "mover")
  await model.navigator.settled()
  #expect(
    surface.shows == 1 && model.navigator.command?.id == "extension:mover"
      && model.navigator.command?.problem?.contains("nope") == true)
  let sent = try logged(root, "mover")
  #expect(sent.count == 1 && sent[0].submitted && sent[0].action == "left")
  await model.navigator.settled()
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
  #expect(LauncherModel.testing(in: root, bundled: nil).navigator.arrivalDeadline == .milliseconds(150))
}

/// A panel that routes keys as if it had them, and records every frame it is given.
@MainActor private final class FramePanel: PalettePanel {
  var frames: [NSRect] = []
  /// The screen shown when each frame was set.
  var screens: [String] = []
  var shows: () -> String = { "" }
  override var isKeyWindow: Bool { true }
  override func setFrame(_ frame: NSRect, display: Bool) {
    frames.append(frame)
    screens.append(shows())
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
  let surface: RecordingSurface
  init(answer: String = finished) async throws {
    let (model, _, root) = try await transitions(answer: answer)
    self.model = model
    self.root = root
    controller = PaletteController(model: model, panel: panel)
    surface = RecordingSurface(wrapping: controller)
    controller.show(orderFront: false, listen: false)
    await model.navigator.settled()
    model.navigator.surface = surface
    surface.onDraw = { [unowned self] in
      shown.append(
        (
          model.agent.active ? "agent" : model.navigator.command?.id ?? "root", model.navigator.input,
          model.navigator.selected?.row.title,
          model.navigator.body, model.navigator.command?.busy == true, panel.frame
        ))
    }
    surface.onPrepare = { [unowned self] page, turn in
      await withCheckedContinuation { held.append($0) }
      return await controller.prepare(page, turn: turn)
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
  model.navigator.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.navigator.command == nil && panel.panel.frame == rootFrame)
  panel.release()
  #expect(await eventually { model.navigator.body == "# First page" })
  await panel.controller.renderer.settled()
  let measured = PaletteLayout.panelHeight(
    card: PaletteLayout.cardHeight(
      model.navigator.presentation, answer: panel.controller.renderer.height,
      cap: panel.controller.renderer.cap))
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
  model.navigator.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.navigator.command == nil)
  model.navigator.passDeadline()
  // The deadline: the command, busy, with its one row, at the list's height.
  let running = PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer)
  #expect(panel.shown.last?.screen == "extension:page" && panel.shown.last?.busy == true)
  #expect(panel.shown.last?.body == nil && panel.panel.frame.height == running)
  panel.release()
  #expect(await eventually { model.navigator.body == "# First page" })
  await panel.controller.renderer.settled()
  let measured = PaletteLayout.panelHeight(
    card: PaletteLayout.cardHeight(
      model.navigator.presentation, answer: panel.controller.renderer.height,
      cap: panel.controller.renderer.cap))
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
  model.navigator.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.navigator.escape())
  let drawn = panel.shown.count
  panel.release()
  try await Task.sleep(for: .milliseconds(200))
  #expect(model.navigator.command == nil && model.navigator.body == nil && panel.shown.count == drawn)
  #expect(panel.panel.frame == rootFrame)
  await panel.finish()
}

@MainActor @Test func aLateErrorOrViewOfAnEntryCalledOffByEscapeChangesNothing() async throws {
  for answer in ["{broken", finished] {
    let (model, _, root) = try await transitions(answer: answer)
    defer { try? FileManager.default.removeItem(at: root) }
    model.navigator.arrivalDeadline = .seconds(60)
    model.navigator.go(Address(id: "slow"), submitted: true)
    #expect(await eventually { (try? logged(root).count) == 1 })
    #expect(model.navigator.escape())
    try release(root)
    try await Task.sleep(for: .milliseconds(200))
    #expect(
      model.navigator.command == nil && model.navigator.input == "a"
        && model.navigator.results.count > 8)
    await model.finish()
  }
}

@MainActor @Test func aRepeatedReturnDuringAnEntryEntersAgainFromTheScreenShown() async throws {
  let (model, apps, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = apps
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "slow"
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.title == "slow")
  model.navigator.arrivalDeadline = .seconds(60)
  controller.run()
  #expect(await eventually { (try? logged(root).count) == 1 })
  // Recorded as it is: the root is still what shows, so Return runs its selected row again, and the
  // second entry replaces the first.
  #expect(model.navigator.command == nil && model.navigator.selected?.row.title == "slow")
  controller.run()
  #expect(await eventually { (try? logged(root).count) == 2 })
  #expect(try logged(root).allSatisfy { $0.submitted && $0.input.isEmpty })
  try release(root)
  await model.navigator.settled()
  #expect(
    model.navigator.command?.id == "extension:slow"
      && model.navigator.results.map(\.row.title) == ["Finished"])
  #expect(try logged(root).count == 2)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aQueuedReturnSendsOneRequestAcrossTheBatchesItWaitsFor() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  var batches = 0
  let surface = RecordingSurface(wrapping: controller)
  model.navigator.surface = surface
  surface.onDraw = { if model.navigator.command == nil { batches += 1 } }
  model.navigator.input = "> B"
  controller.run()
  // The held pattern lets the list compose without it first: Return keeps waiting.
  #expect(await eventually { batches >= 1 })
  #expect(model.navigator.command == nil)
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  await model.navigator.settled()
  let submitted = try logged(root, "echo").filter(\.submitted)
  #expect(submitted.count == 1 && submitted[0].input == "> B")
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysThroughTheActionPanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate",
    fields: [
      "fields": [
        ["name": "hours", "type": "number", "description": "Hours"],
        ["name": "minutes", "type": "number", "description": "Minutes"],
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.input = "caffeinate"
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "command" && model.navigator.fieldSlots.count == 2)
  model.navigator.setField("hours", to: "2")
  model.navigator.focusedField = "hours"
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == "caffeinate" && model.navigator.fieldSlots.isEmpty)
  #expect(model.navigator.escape())
  #expect(model.navigator.fieldValues == ["hours": "2"] && model.navigator.selected?.row.id == "command")
  // Return on the row itself enters with the draft; ⌘K runs the row's action as it was captured.
  guard case .run(let entered)? = model.navigator.returnAction?.kind else { throw CancellationError() }
  #expect(entered.fields == ["hours": "2"])
  model.navigator.toggleActions()
  let picked = try #require(model.navigator.pick())
  #expect(picked.from?.row.id == "command" && model.navigator.actionsTitle == nil)
  guard case .run(let captured) = picked.action.kind else { throw CancellationError() }
  #expect(captured.fields == nil && model.navigator.fieldValues == ["hours": "2"])
  await model.finish()
}

@MainActor @Test func editingASubmitCommandInsideADetailLeavesTheDetailsTarget() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(body: "<row title=\"Notes\" copy=\"note\">Additional details</row>")
  let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "report", script: "cat >/dev/null\nprintf '%s' '\(json)'",
    fields: [
      "submit": true,
      "fields": [
        ["name": "query", "type": "text", "description": "Search"],
        ["name": "format", "type": "text", "description": "Format"],
      ],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.go(Address(id: "report"), submitted: true)
  await model.navigator.settled()
  model.navigator.move(1)
  #expect(model.activateReturn() && model.navigator.inDetail)
  // Typing, then filling a slot, in the detail: Return sends the edited request, not the detail's Copy.
  model.navigator.move(1)
  #expect(model.navigator.returnAction?.kind == .copy("note"))
  model.navigator.editInput("updated")
  #expect(
    model.navigator.inDetail && model.navigator.selection == nil
      && model.navigator.selected?.row.id == "submit")
  model.navigator.move(1)
  #expect(model.navigator.returnAction?.kind == .copy("note"))
  model.navigator.setField("format", to: "json")
  #expect(
    model.navigator.inDetail && model.navigator.selection == nil
      && model.navigator.selected?.row.id == "submit")
  // Sending it replaces the page: the fresh one starts with nothing selected.
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(
    !model.navigator.inDetail && model.navigator.selection == nil
      && model.navigator.selected?.row.id == "submit")
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
  model.navigator.go(Address(id: "report"), submitted: true)
  await model.navigator.settled()
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
  #expect(model.navigator.results.map(\.row.title) == ["Notes", "Owner"])
  // The selected target is scrolled into view, then the page a little further.
  model.navigator.move(1)
  #expect(model.navigator.selectedTarget == "#0")
  let page = try await scrollY(controller) + 40
  try await scroll(controller, to: page)
  #expect(try await scrollY(controller) == page)
  // ⌘K and back: the page stays mounted where it was. Recorded as it is: unpainting the selected
  // target under the panel moves the page by a few points, and Escape keeps that position.
  model.navigator.toggleActions()
  let under = try await scrollY(controller)
  #expect(model.navigator.selectedTarget == nil && abs(under - page) <= 8)
  #expect(model.navigator.escape())
  #expect(try await scrollY(controller) == under && model.navigator.selectedTarget == "#0")
  // A detail, a detail inside it, and back twice: each page where it was, with its target selected.
  #expect(model.activateReturn())
  #expect(try await scrollY(controller) == 0 && model.navigator.inDetail)
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.title == "Deeper")
  let detail = try await scrollY(controller) + 40
  try await scroll(controller, to: detail)
  #expect(model.activateReturn())
  #expect(try await scrollY(controller) == 0)
  #expect(model.navigator.escape())
  #expect(try await scrollY(controller) == detail && model.navigator.selected?.row.title == "Deeper")
  #expect(model.navigator.escape())
  #expect(
    try await scrollY(controller) == under && !model.navigator.inDetail
      && model.navigator.selectedTarget == "#0")
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
  model.navigator.send("What is on today?")
  #expect(await eventually { fake.running })
  fake.text("Today.\n<row title=\"Tue\" copy=\"tue\"/>")
  #expect(await eventually { model.navigator.results.count == 1 })
  model.navigator.move(1)
  #expect(controller.panel.route(voiceKey(40, "k", .command)) && model.navigator.actionsTitle == "Tue")
  fake.ask()
  #expect(model.navigator.actionsTitle == nil)
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
/// `selecting` is where it is composed, replacing what is selected there; the end by default.
@MainActor private func compose(_ marked: String, in field: NSTextField, selecting: NSRange? = nil) throws
  -> NSTextView
{
  let editor = try #require(field.currentEditor() as? NSTextView)
  editor.setSelectedRange(selecting ?? NSRange(location: (editor.string as NSString).length, length: 0))
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

@Test(arguments: [
  ("", ""),
  ("日本語 👋  two spaces", "日本語 👋  two spaces"),
  ("first\r\n\n\rlast", "first last"),
  ("\nfirst\u{2028}\u{2029}last\r\n", " first last "),
])
func searchInputCollapsesRunsOfLineBreaks(_ text: String, _ expected: String) {
  #expect(text.singleLineInput == expected)
}

@MainActor @Test func longSearchEditsScrollToTheCaretOffscreen() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  let field = try #require(controller.panel.field)
  let editor = try #require(field.currentEditor() as? NSTextView)
  let layout = try #require(editor.layoutManager)
  let container = try #require(editor.textContainer)
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  let prefix = String(repeating: "transcript ", count: 600)
  #expect(pasteboard.setString(prefix + "first\r\n\nlast words", forType: .string))

  func expectVisibleEnd(_ text: String) {
    #expect(editor.string == text)
    #expect(model.navigator.input == text)
    let end = text.utf16.count
    #expect(editor.selectedRange() == NSRange(location: end, length: 0))
    let lastGlyph = layout.glyphRange(
      forCharacterRange: NSRange(location: end - 1, length: 1), actualCharacterRange: nil)
    let lastX =
      layout.boundingRect(forGlyphRange: lastGlyph, in: container).midX + editor.textContainerOrigin.x
    #expect(editor.visibleRect.minX > 0)
    #expect((editor.visibleRect.minX..<editor.visibleRect.maxX).contains(lastX))
    #expect(editor.bounds.height < 2 * field.intrinsicContentSize.height)
  }

  #expect(editor.readSelection(from: pasteboard))
  try await update(controller)
  expectVisibleEnd(prefix + "first last words")
  commit(" appended", in: editor)
  try await update(controller)
  expectVisibleEnd(prefix + "first last words appended")

  model.navigator.dictate(prefix + "other\r\n\nwords")
  try await update(controller)
  expectVisibleEnd(prefix + "other words")
  field.setFrameSize(NSSize(width: field.frame.width - 100, height: field.frame.height))
  expectVisibleEnd(prefix + "other words")
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionInTheActionPanelsFieldBecomesTheInputWhenCommitted() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "settings"
  await model.navigator.settled()
  model.navigator.toggleActions()
  try await update(controller)
  let field = try #require(controller.panel.field)
  #expect(model.navigator.actionsTitle == "Settings" && field.stringValue.isEmpty)
  let editor = try compose("か", in: field)
  try await update(controller)
  #expect(model.navigator.actionsTitle == "Settings" && model.navigator.input == "settings")
  #expect(editor.hasMarkedText() && field.stringValue == "か")
  // Committed, it closes the panel and is the whole input; the field is not written again.
  commit("か", in: editor)
  try await update(controller)
  #expect(model.navigator.actionsTitle == nil && model.navigator.input == "か" && field.stringValue == "か")
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionDuringAnEntryIsAddedWhenCommittedAndOutlivesTheDeadline() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  await model.navigator.settled()
  model.navigator.arrivalDeadline = .seconds(60)
  model.navigator.go(Address(id: "slow"), submitted: true)
  try await update(controller)
  let field = try #require(controller.panel.field)
  var editor = try compose("か", in: field)
  try await update(controller)
  #expect(
    model.navigator.command == nil && model.navigator.input == "a" && editor.hasMarkedText()
      && field.stringValue == "aか")
  // Committed, what was added to the old input is the new one's, and the field is rewritten to it.
  commit("か", in: editor)
  try await update(controller)
  #expect(
    model.navigator.command?.id == "extension:slow" && model.navigator.input == "か"
      && field.stringValue == "か")
  // A composition still open when the deadline shows the command.
  _ = model.navigator.escape()
  model.navigator.dismiss()
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "a"
  await model.navigator.settled()
  model.navigator.arrivalDeadline = .seconds(60)
  model.navigator.go(Address(id: "slow"), submitted: true)
  try await update(controller)
  editor = try compose("か", in: field)
  model.navigator.passDeadline()
  #expect(model.navigator.command != nil)
  try await update(controller)
  // The field is not written under the composition, which stays open.
  #expect(model.navigator.input.isEmpty && field.stringValue == "aか" && editor.hasMarkedText())
  // Committed, it goes after the command's own input, not after the root's.
  commit("か", in: editor)
  try await update(controller)
  #expect(model.navigator.input == "か" && field.stringValue == "か" && !editor.hasMarkedText())
  #expect(await eventually { (try? logged(root).contains { $0.input == "か" && !$0.submitted }) == true })
  #expect(try !logged(root).contains { $0.input == "aか" })
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionInsideTheFieldCarriesOnlyWhatItCommittedIntoTheEntry() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  let field = try #require(controller.panel.field)
  // Between the letters while the deadline shows the command, over a selected letter likewise, and
  // between the letters before the deadline, where the commit is the edit that enters the command.
  for (typed, at, deadline, shown) in [
    ("ab", NSRange(location: 1, length: 0), true, "aかb"),
    ("abc", NSRange(location: 1, length: 1), true, "aかc"),
    ("ab", NSRange(location: 1, length: 0), false, "aかb"),
  ] {
    model.navigator.dismiss()
    controller.show(orderFront: false, listen: false)
    model.navigator.input = typed
    await model.navigator.settled()
    try await update(controller)
    model.navigator.arrivalDeadline = .seconds(60)
    model.navigator.go(Address(id: "slow"), submitted: true)
    try await update(controller)
    let editor = try compose("か", in: field, selecting: at)
    if deadline { model.navigator.passDeadline() }
    try await update(controller)
    #expect(field.stringValue == shown && editor.hasMarkedText())
    #expect((model.navigator.command != nil) == deadline)
    commit("か", in: editor)
    try await update(controller)
    #expect(model.navigator.command?.id == "extension:slow" && model.navigator.input == "か")
    #expect(field.stringValue == "か" && !editor.hasMarkedText())
    #expect(await eventually { (try? logged(root).contains { $0.input == "か" && !$0.submitted }) == true })
    #expect(try !logged(root).contains { $0.input.contains("a") && $0.input.contains("か") })
    _ = model.navigator.escape()
  }
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCompositionReplacingSelectedTextCarriesAllOfItIntoTheEntry() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  let field = try #require(controller.panel.field)
  // `か` selected in `aかc` and replaced by a composition that starts with it, or by itself again, on
  // both sides of the deadline: the old letter is not what the field kept.
  for (committed, deadline) in [("かな", true), ("かな", false), ("か", true), ("か", false)] {
    model.navigator.dismiss()
    controller.show(orderFront: false, listen: false)
    model.navigator.input = "aかc"
    await model.navigator.settled()
    try await update(controller)
    model.navigator.arrivalDeadline = .seconds(60)
    model.navigator.go(Address(id: "slow"), submitted: true)
    try await update(controller)
    let editor = try compose(committed, in: field, selecting: NSRange(location: 1, length: 1))
    if deadline { model.navigator.passDeadline() }
    try await update(controller)
    commit(committed, in: editor)
    try await update(controller)
    #expect(
      model.navigator.command?.id == "extension:slow" && model.navigator.input == committed,
      "\(committed) \(deadline): \(model.navigator.input)")
    #expect(field.stringValue == committed && !editor.hasMarkedText())
    #expect(
      await eventually { (try? logged(root).last.map { $0.input == committed && !$0.submitted }) == true })
    _ = model.navigator.escape()
  }
  controller.hide()
  await model.finish()
}

@Test func anEditKnowsWhatItInserted() {
  #expect(InputEdit("ab", from: "a").inserted == "b")
  #expect(InputEdit("aかb", from: "ab", endingAt: 2).inserted == "か")
  // A replacement that starts with what it replaced, where the field says it began.
  #expect(InputEdit("aかなc", from: "aかc", endingAt: 3).inserted == "な")
  #expect(InputEdit("aかなc", from: "aかc", startingBy: 1, endingAt: 3).inserted == "かな")
  #expect(InputEdit("aかc", from: "aかc", startingBy: 1, endingAt: 2).inserted == "か")
  #expect(InputEdit("axc", from: "abc", endingAt: 2).inserted == "x")
  // Among repeated letters, the caret says which one is new.
  #expect(InputEdit("aaa", from: "aa", endingAt: 1).inserted == "a")
  #expect(InputEdit("a", from: "ab").inserted.isEmpty)
  #expect(InputEdit("😁", from: "😀").inserted == "😁")
  #expect(InputEdit("z", from: "a").inserted == "z")
}

@MainActor @Test func aCompositionInASlotIsItsValueWhenCommitted() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "note",
    fields: [
      "fields": [
        ["name": "title", "type": "text", "description": "Title"],
        ["name": "limit", "type": "number", "description": "Limit"],
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "note"
  await model.navigator.settled()
  model.navigator.focusedField = "title"
  try await update(controller)
  let content = try #require(controller.panel.contentView)
  let slot = try #require(fields(in: content).first { $0.accessibilityLabel() == "title" })
  #expect(controller.panel.firstResponder === slot.currentEditor())
  let editor = try compose("か", in: slot)
  try await update(controller)
  #expect(model.navigator.fieldValues.isEmpty && editor.hasMarkedText() && slot.stringValue == "か")
  commit("か", in: editor)
  try await update(controller)
  #expect(
    model.navigator.fieldValues == ["title": "か"] && model.navigator.input == "note"
      && slot.stringValue == "か")
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  #expect(pasteboard.setString("first\r\n\nlast ", forType: .string))
  editor.setSelectedRange(NSRange(location: 0, length: 0))
  #expect(editor.readSelection(from: pasteboard))
  try await update(controller)
  #expect(model.navigator.fieldValues == ["title": "first last か"] && model.navigator.input == "note")
  #expect(slot.stringValue == "first last か")
  #expect(editor.selectedRange() == NSRange(location: "first last ".utf16.count, length: 0))
  controller.hide()
  await model.finish()
}

@MainActor @Test func tabFocusesTheEditableSlotWhenAnItemFixesTheMainTextField() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "search",
    fields: [
      "fields": [
        ["name": "site", "type": "text", "description": "Site"],
        ["name": "query", "type": "text", "description": "Query"],
      ],
      "items": [
        ["id": "yt", "title": "YouTube", "actions": [["type": "run", "fields": ["site": "YouTube"]]]]
      ],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  defer { controller.hide() }
  let nav = model.navigator
  nav.editInput("YouTube")
  await nav.settled()
  try await update(controller)
  let content = try #require(controller.panel.contentView)
  #expect(fields(in: content).count == 1)
  #expect(controller.handle(.focus(1)) && nav.focusedField == "query")
  try await update(controller)
  let slot = try #require(fields(in: content).first { $0.accessibilityLabel() == "query" })
  let editor = try #require(slot.currentEditor())
  #expect(controller.panel.firstResponder === editor && nav.input == "YouTube")
  await model.finish()
}

@MainActor @Test func anEmptyQuestionDuringAnEntryCallsItOffWithItsRequest() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.go(Address(id: "page"), submitted: true)
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:page" && model.navigator.body == "# First page")
  // A page on its way over the first one, and ⌘↩ with nothing typed while it is measured.
  model.navigator.arrivalDeadline = .seconds(60)
  var measuring: CheckedContinuation<Void, Never>?
  surface.onPrepare = { _, _ in
    await withCheckedContinuation { measuring = $0 }
    return .unmeasured
  }
  model.navigator.go(Address(id: "other"), submitted: true)
  #expect(await eventually { measuring != nil })
  model.navigator.askAgent()
  #expect(
    model.agent.active && model.navigator.returnsOnEscape && model.navigator.command?.id == "extension:page")
  measuring?.resume()
  await model.navigator.settled()
  // The first command, exactly as it was under the question.
  #expect(model.navigator.escape())
  #expect(
    model.navigator.command?.id == "extension:page" && model.navigator.body == "# First page"
      && !model.agent.active)
  // The late answer of an entry called off this way shows nothing.
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  model.navigator.askAgent()
  try release(root)
  try await Task.sleep(for: .milliseconds(200))
  #expect(model.agent.active && model.navigator.returnsOnEscape)
  #expect(model.navigator.escape())
  #expect(model.navigator.command?.id == "extension:page" && model.navigator.body == "# First page")
  #expect(try logged(root, "page").count == 1 && logged(root, "other").count == 1)
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysUnderAnEmptyQuestion() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate",
    fields: [
      "fields": [
        ["name": "hours", "type": "number", "description": "Hours"],
        ["name": "minutes", "type": "number", "description": "Minutes"],
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  await model.extensions.reload()
  model.navigator.refresh()
  await model.navigator.settled()
  let row = try #require(model.navigator.results.first { $0.provider == "extension:caffeinate" }?.id)
  model.navigator.select(row)
  model.navigator.setField("hours", to: "2")
  // The question has its own input, values and selection; Escape finds the root as it was.
  model.navigator.askAgent()
  #expect(model.agent.active && model.navigator.fieldValues.isEmpty && model.navigator.selection == nil)
  model.navigator.editInput("how long")
  #expect(model.navigator.escape())
  #expect(
    model.navigator.input.isEmpty && model.navigator.selection == row
      && model.navigator.fieldValues == ["hours": "2"])
  // Sending instead leaves the draft behind with the root.
  model.navigator.askAgent()
  model.navigator.editInput("how long")
  #expect(model.activateReturn() && model.agent.question == "how long")
  model.agent.cancel()
  #expect(await eventually { !model.agent.busy })
  #expect(model.navigator.escape())
  await model.navigator.settled()
  #expect(!model.agent.active && model.navigator.input.isEmpty && model.navigator.fieldValues.isEmpty)
  await model.finish()
}

@MainActor @Test func aCommandRowsDraftStaysUnderAnEmptyQuestionKeptWhileHidden() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate",
    fields: ["fields": [["name": "hours", "type": "number", "description": "Hours"]]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.refresh()
  await model.navigator.settled()
  let row = try #require(model.navigator.results.first { $0.provider == "extension:caffeinate" }?.id)
  model.navigator.select(row)
  model.navigator.setField("hours", to: "2")
  model.navigator.askAgent()
  model.navigator.editInput("how long")
  // Hidden and shown again, the question is kept, and Escape still finds the root as it was.
  model.navigator.dismiss()
  model.reopen()
  #expect(model.navigator.returnsOnEscape && model.navigator.input == "how long")
  #expect(model.navigator.escape())
  #expect(model.navigator.selection == row && model.navigator.fieldValues == ["hours": "2"])
  // Leaving the question for the root another way, by a link, starts the root over.
  model.navigator.askAgent()
  model.navigator.go(Address(input: ""))
  await model.navigator.settled()
  #expect(!model.agent.active && model.navigator.command == nil && model.navigator.fieldValues.isEmpty)
  model.navigator.select(row)
  model.navigator.setField("hours", to: "2")
  // Hiding the root itself drops them.
  model.navigator.dismiss()
  model.reopen()
  #expect(model.navigator.fieldValues.isEmpty)
  // So does the question expiring while hidden: the root starts over.
  model.navigator.select(row)
  model.navigator.setField("hours", to: "3")
  model.navigator.askAgent()
  model.navigator.dismiss()
  model.reopen(now: Date().addingTimeInterval(60 * 60))
  #expect(!model.agent.active && model.navigator.fieldValues.isEmpty)
  await model.finish()
}

@MainActor @Test func aPermissionDeliveredWhileHiddenTakesTheKeysWhenShown() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.update { $0.resultsOnlyWhenTyping = true }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  #expect(!controller.presentation.showsCard)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.navigator.send("Update the weather extension")
  #expect(await eventually { fake.running })
  fake.text("Working on it.\n<row title=\"Tue\" copy=\"tue\"/>")
  #expect(await eventually { model.navigator.results.count == 1 })
  model.navigator.move(1)
  controller.hide()
  fake.ask()
  #expect(model.agent.permissions.count == 1 && fake.decisions.isEmpty)
  controller.show(orderFront: false, listen: false)
  // The card is what shows: ⌘K waits, Return decides nothing, ⌘↩ allows.
  #expect(controller.presentation.showsCard && controller.presentation.permissionPending)
  #expect(model.agent.active && model.agent.permissions.count == 1 && model.navigator.actionsTitle == nil)
  #expect(controller.panel.route(voiceKey(40, "k", .command)) && model.navigator.actionsTitle == nil)
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
  model.navigator.arrivalDeadline = .milliseconds(1)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { model.navigator.command?.busy == true })
  model.navigator.askAgent()
  model.navigator.editInput("is it slow")
  // Escape before sending: the command, still running, with its own empty input.
  #expect(model.navigator.escape())
  #expect(!model.agent.active && model.navigator.command?.busy == true && model.navigator.input.isEmpty)
  let trace = Trace(model)
  try release(root)
  await model.navigator.settled()
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
  model.navigator.arrivalDeadline = .seconds(60)
  try release(panel.root)
  model.navigator.go(Address(id: "slow"), submitted: true)
  await model.navigator.settled()
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.title == "Second")
  model.navigator.askAgent()
  model.navigator.editInput("why")
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  fake.text("Because.")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.navigator.editInput("and then")
  try FileManager.default.removeItem(at: panel.root.appending(path: "extensions/slow/release"))
  let drawn = panel.shown.count
  let frames = panel.panel.frames.count
  let top = panel.panel.frame.maxY
  // Escape stages the way back and a second one waits for it: the conversation stays as it is.
  #expect(model.navigator.escape())
  #expect(model.navigator.escape())
  #expect(await eventually { (try? logged(panel.root).count) == 2 })
  #expect(model.agent.active && model.navigator.input == "and then" && model.navigator.selection == nil)
  #expect(model.navigator.command?.busy == false && panel.panel.frames.count == frames)
  #expect(panel.shown.dropFirst(drawn).allSatisfy { $0.screen == "agent" && $0.input == "and then" })
  try release(panel.root)
  #expect(await eventually { !model.agent.active })
  await model.navigator.settled()
  // One handoff: the command with a blank input, its first row, at the list's height, the top edge where
  // it was.
  let back = panel.shown.dropFirst(drawn).filter { $0.screen != "agent" }
  let last = try #require(back.last)
  #expect(back.count == 1 && last.screen == "extension:slow" && last.input.isEmpty)
  #expect(last.selection == "First" && !last.busy && last.frame.height == listHeight)
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
  model.navigator.go(Address(id: "counter"), submitted: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["View 1"])
  // A rerun on its way, held, when ⌘↩ with nothing typed opens the question over it.
  let hold = root.appending(path: "extensions/counter/hold")
  try Data().write(to: hold)
  model.navigator.refresh()
  #expect(await eventually(within: .seconds(3)) { (try? logged(root, "counter").count) == 2 })
  model.navigator.askAgent()
  #expect(model.agent.active && model.navigator.returnsOnEscape && model.navigator.command?.busy == true)
  // The covered rerun finishes under the question, before it is sent.
  try FileManager.default.removeItem(at: hold)
  #expect(await eventually(within: .seconds(3)) { model.navigator.command?.busy == false })
  #expect(model.navigator.command?.shown.view.items.map(\.title) == ["View 2"])
  model.navigator.editInput("what is this")
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
  model.navigator.go(Address(id: "notes"), submitted: true)
  #expect(model.navigator.command?.id == "extension:notes")
  let trace = Trace(model)
  model.navigator.go(Address(extensionName: "agent", input: "Why?"), from: "extension:notes")
  #expect(
    model.agent.active && model.navigator.command == nil && model.navigator.input == "Why?"
      && !model.navigator.returnsOnEscape)
  #expect(model.navigator.escape())
  await model.navigator.settled()
  #expect(!model.agent.active && model.navigator.command == nil && model.navigator.input.isEmpty)
  #expect(
    trace.screens == ["agent", "root"]
      && trace.frames.last?.selection == model.navigator.results.first?.row.title)
  await model.finish()
}

private let page = String(
  decoding: try! JSONEncoder().encode(ProviderView(body: "# Late page")), as: UTF8.self)

@MainActor @Test func theDeadlineThenTheAnswerShowsRunningThenThePageRenderedWhereItShows() async throws {
  let panel = try await Measured(answer: page)
  let model = panel.model
  model.navigator.arrivalDeadline = .seconds(60)
  let rootFrame = panel.panel.frame
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(panel.root).count) == 1 })
  model.navigator.passDeadline()
  let running = PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer)
  #expect(model.navigator.command?.busy == true && panel.panel.frame.height == running)
  try release(panel.root)
  #expect(await eventually { model.navigator.body == "# Late page" })
  await panel.controller.renderer.settled()
  // Shown already, the page is rendered where it shows rather than measured first.
  #expect(panel.measuring == 0)
  let measured = PaletteLayout.panelHeight(
    card: PaletteLayout.cardHeight(
      model.navigator.presentation, answer: panel.controller.renderer.height,
      cap: panel.controller.renderer.cap))
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
  model.navigator.arrivalDeadline = .seconds(60)
  try release(panel.root)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.navigator.body == "# Late page" })
  let drawn = panel.shown.count
  let frames = panel.panel.frames
  model.navigator.passDeadline()
  #expect(panel.shown.count == drawn && panel.panel.frames == frames)
  #expect(panel.shown.map(\.screen) == ["root", "extension:slow"] && panel.shown.allSatisfy { !$0.busy })
  await panel.finish()
}

@MainActor @Test func pageToPageKeepsTheOutgoingPageAndFrameUntilTheIncomingOneIsMeasured() async throws {
  let panel = try await Measured()
  let model = panel.model
  model.navigator.arrivalDeadline = .seconds(60)
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.navigator.body == "# First page" })
  await panel.controller.renderer.settled()
  let first = panel.panel.frame
  let drawn = panel.shown.count
  let frames = panel.panel.frames.count
  model.navigator.go(Address(id: "other"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  #expect(model.navigator.command?.id == "extension:page" && model.navigator.body == "# First page")
  #expect(panel.panel.frame == first && panel.panel.frames.count == frames)
  panel.release()
  #expect(await eventually { model.navigator.body == "# Second page" })
  await panel.controller.renderer.settled()
  #expect(panel.shown.dropFirst(drawn).map(\.screen).last == "extension:other")
  #expect(panel.shown.allSatisfy { !$0.busy })
  // Both one-line pages measure the same, so the frame never moves.
  #expect(panel.panel.frame == first && panel.panel.frames.count == frames)
  #expect(try logged(panel.root, "page").count == 1 && logged(panel.root, "other").count == 1)
  await panel.finish()
}

@MainActor @Test func pageToPageOfAnotherHeightResizesOnlyWhenTheIncomingPageShows() async throws {
  let panel = try await Measured()
  let model = panel.model
  let tall = (1...12).map { "Paragraph \($0) of a page taller than one line." }.joined(separator: "\n\n")
  let view = String(decoding: try JSONEncoder().encode(ProviderView(body: tall)), as: UTF8.self)
  _ = try extensionFolder(panel.root, name: "tall", script: "cat >/dev/null\nprintf '%s' '\(view)'")
  await model.extensions.reload()
  model.navigator.arrivalDeadline = .seconds(60)
  panel.panel.shows = { model.navigator.command?.id ?? "root" }
  model.navigator.go(Address(id: "page"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.navigator.body == "# First page" })
  await panel.controller.renderer.settled()
  let first = panel.panel.frame
  let frames = panel.panel.frames.count
  model.navigator.go(Address(id: "tall"), submitted: true)
  #expect(await eventually { panel.measuring == 1 })
  panel.release()
  #expect(await eventually { model.navigator.command?.id == "extension:tall" })
  await panel.controller.renderer.settled()
  let measured = PaletteLayout.panelHeight(
    card: PaletteLayout.cardHeight(
      model.navigator.presentation, answer: panel.controller.renderer.height,
      cap: panel.controller.renderer.cap))
  // The first page keeps its frame while the tall one is measured; one frame, at the tall page's height,
  // comes with the tall page.
  #expect(measured > first.height + 100)
  #expect(Array(panel.panel.screens.dropFirst(frames)) == ["extension:tall"])
  #expect(panel.panel.frames.dropFirst(frames).map(\.height) == [measured])
  #expect(panel.shown.last?.screen == "extension:tall" && panel.shown.last?.frame.height == measured)
  await panel.finish()
}

@MainActor @Test func aMeasurementEndingAfterAReplacementOrHidingChangesNothing() async throws {
  for replaced in [true, false] {
    let panel = try await Measured()
    let model = panel.model
    model.navigator.arrivalDeadline = .seconds(60)
    model.navigator.go(Address(id: "page"), submitted: true)
    #expect(await eventually { panel.measuring == 1 })
    if replaced {
      model.navigator.go(Address(id: "notes"), submitted: true)
      #expect(model.navigator.command?.id == "extension:notes")
    } else {
      panel.controller.hide()
    }
    // Hiding composes the empty root; the measurement is still held.
    await model.root.settled()
    let turn = model.navigator.pageTurn
    let drawn = panel.shown.count
    let frame = panel.panel.frame
    panel.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(
      model.navigator.command?.id == (replaced ? "extension:notes" : nil) && model.navigator.body == nil)
    #expect(model.navigator.pageTurn == turn && panel.shown.count == drawn && panel.panel.frame == frame)
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
  for answer in ["{broken", finished] {
    for replaced in [true, false] {
      let (model, _, root) = try await transitions()
      defer { try? FileManager.default.removeItem(at: root) }
      _ = try extensionFolder(root, name: "late", script: printing(answer))
      await model.extensions.reload()
      model.navigator.arrivalDeadline = .seconds(60)
      model.navigator.go(Address(id: "late"), submitted: true)
      #expect(await eventually { (try? logged(root, "late").count) == 1 })
      try release(root, "late")
      blockUntilPrinted(root, "late")
      if replaced {
        model.navigator.go(Address(id: "notes"), submitted: true)
      } else {
        model.navigator.dismiss()
      }
      let turn = model.navigator.command?.turn
      await model.navigator.settled()
      try await Task.sleep(for: .milliseconds(100))
      #expect(model.navigator.command?.id == (replaced ? "extension:notes" : nil), "\(answer)")
      #expect(model.navigator.command?.problem == nil && model.navigator.command?.turn == turn)
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
  model.navigator.go(Address(id: "pager"), submitted: true)
  await model.navigator.settled()
  let trace = Trace(model)
  #expect(model.activateReturn())
  // No switch: the same command, its rows kept while its request runs, then its answer.
  #expect(
    model.navigator.command?.id == "extension:pager" && model.navigator.input == "page 2"
      && model.navigator.command?.busy == true)
  #expect(model.navigator.results.map(\.row.title) == ["Next"])
  await model.navigator.settled()
  #expect(trace.screens == ["extension:pager"] && trace.frames.first?.busy == true)
  #expect(trace.frames.last?.busy == false && trace.frames.last?.selection == "Next")
  let sent = try logged(root, "pager")
  #expect(sent.count == 2 && sent[1].submitted && sent[1].input == "page 2")
  await model.finish()
}

@MainActor @Test func aHiddenRunsViewNeverReplacesTheScreenTheUserOpenedMeanwhile() async throws {
  let (model, _, root) = try await transitions()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "mover",
    script: printing(#"{"items":[{"id":"moved","title":"Not moved","actions":[]}]}"#),
    fields: [
      "items": [
        [
          "id": "left", "title": "Left half",
          "actions": [["type": "run", "action": "left", "hidden": true]],
        ]
      ]
    ])
  await model.extensions.reload()
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  model.press(HotkeyTarget(target: "extension:mover", item: "left"))
  #expect(await eventually { (try? logged(root, "mover").count) == 1 })
  // The user opens the panel, types and enters a command while the run goes on: it is not stopped.
  surface.shown = true
  model.navigator.editInput("b")
  model.navigator.arrivalDeadline = .seconds(60)
  model.navigator.go(Address(id: "slow"), submitted: true)
  #expect(await eventually { (try? logged(root).count) == 1 })
  try release(root, "mover")
  #expect(await eventually { model.navigator.actionProblem == "mover: Not moved" })
  #expect(surface.shows == 0 && model.navigator.command == nil)
  // The entry it did not replace arrives with its own answer, and nothing ran twice.
  try release(root)
  await model.navigator.settled()
  #expect(
    model.navigator.command?.id == "extension:slow"
      && model.navigator.results.map(\.row.title) == ["Finished"])
  #expect(try logged(root, "mover").count == 1 && logged(root).count == 1)
  await model.finish()
}

@MainActor @Test func quittingEndsTheAgentsScreenAndItsDetailBeforeTheSession() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  try await finishTurn(model, "What shipped?", "Done.\n<row title=\"Notes\" copy=\"n\">More</row>")
  model.navigator.move(1)
  #expect(model.activateReturn() && model.navigator.inDetail)
  var drawn: [Bool] = []
  let surface = RecordingSurface()
  model.navigator.surface = surface
  surface.onDraw = { drawn.append(model.navigator.inDetail) }
  // Quitting resets the session too: the agent's screen ends first, and nothing of it is drawn after.
  await model.finish()
  #expect(!model.agent.active && !model.navigator.inDetail && model.navigator.page == nil)
  #expect(!drawn.isEmpty && drawn.allSatisfy { !$0 })
}

@MainActor @Test func aMeasurementSupersededInFlightNeverResizesThePageShown() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  let short = Page(body: "One line.", runs: false)
  let tall = Page(
    body: (1...12).map { "Paragraph \($0) of a page taller than one line." }.joined(separator: "\n\n"),
    runs: false)
  renderer.opened()
  renderer.update(short, turn: "shown", streaming: false)
  await renderer.settled()
  let height = renderer.height
  var published: [Double] = []
  renderer.onHeight = { published.append(renderer.height) }
  // A redraw of the page shown (an appearance or text-size change) lands while the incoming tall page is
  // rendered to be measured, at several points of that render; a warm render takes about a millisecond.
  var superseded = 0
  for steps in 1...6 {
    let turn = "incoming \(steps)"
    let measuring = Task { await renderer.measure(tall, turn: turn) }
    for _ in 0..<steps { await Task.yield() }
    renderer.update(short, turn: "shown", streaming: false)
    let result = await measuring.value
    if result == .superseded {
      superseded += 1
    } else if case .measured(let page) = result {
      #expect(page.turn == turn && page.height > height)
    }
    await renderer.settled()
    #expect(renderer.height == height && renderer.renderedTurn == "shown")
  }
  #expect(superseded > 0)
  #expect(published.allSatisfy { $0 == height }, "\(published)")
}
