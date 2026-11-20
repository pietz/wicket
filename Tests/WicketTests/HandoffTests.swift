import AppKit
import Foundation
import Testing

@testable import WicketApp

// What the panel hands the screens and back: Return while an application opens, dictation when the
// screens write the input themselves, and the panel's own lifetime.

/// An application that opens only when the test says so.
@MainActor private final class HeldOpen {
  var opened: [URL] = []
  private var done: [@MainActor (Error?) -> Void] = []
  func open(_ url: URL, _ completion: @escaping @MainActor (Error?) -> Void) {
    opened.append(url)
    done.append(completion)
  }
  func finish() {
    for completion in done { completion(nil) }
    done.removeAll()
  }
}
/// An application bundle in `root`, so the open policy lets it open.
private func application(in root: URL) throws -> RowAction {
  let bundle = root.appending(path: "Slow.app")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  return RowAction(.open(bundle))
}

@MainActor @Test func nothingRunsWhileAnApplicationOpens() async throws {
  let held = HeldOpen()
  let (model, controller, root) = try await staleReturn(openApplication: held.open)
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try application(in: root)
  let echo = root.appending(path: "extensions/echo")
  let before = try requests(in: echo).count
  controller.run(app)
  #expect(held.opened.count == 1 && model.navigator.results.first?.row.title == "> A")
  // Return on the pattern's row would enter its command: it does nothing, nor in the action panel,
  // which stays open.
  controller.run()
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == "> A")
  controller.run()
  controller.run(app)
  #expect(model.navigator.actionsTitle == "> A" && model.navigator.command == nil && held.opened.count == 1)
  try await Task.sleep(for: .milliseconds(100))
  #expect(try requests(in: echo).count == before && model.navigator.command == nil)
  held.finish()
  #expect(!controller.panel.isVisible && model.navigator.command == nil)
  await model.finish()
}

@MainActor @Test func aWaitingReturnDoesNotRunWhileAnApplicationOpens() async throws {
  let held = HeldOpen()
  let (model, controller, root) = try await staleReturn(openApplication: held.open)
  defer { try? FileManager.default.removeItem(at: root) }
  let app = try application(in: root)
  model.navigator.input = "> B"
  controller.run()
  #expect(model.navigator.returnQueued)
  // A menu item chosen meanwhile opens an application; the rows the Return waited for arrive during it.
  controller.run(app)
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.navigator.results.first?.row.title == "> B" })
  await model.navigator.settled()
  #expect(!model.navigator.returnQueued && model.navigator.command == nil)
  #expect(try !requests(in: root.appending(path: "extensions/echo")).contains { $0.submitted })
  held.finish()
  await model.finish()
}

@MainActor private func listening(_ controller: PaletteController, _ fake: FakeTranscriber) async -> Bool {
  controller.model.store.update { $0.voice.enabled = true }
  controller.input.toggle()
  fake.feeds.last?.yield(.ready)
  return await eventually { controller.input.voice?.state == .listening }
}

@MainActor @Test func aPrefillStopsDictationBeforeItWritesTheInput() async throws {
  let fake = FakeTranscriber()
  let (model, controller, root) = try await staleReturn(transcriber: { fake })
  defer { try? FileManager.default.removeItem(at: root) }
  model.agent.connect = { _, _, _ in FakeAgent() }
  #expect(await listening(controller, fake))
  // A `wicket://agent?input=…` link in a page.
  let link = try #require(URL(string: "wicket://agent?input=Prefilled"))
  model.navigator.go(try #require(Address(url: link)))
  #expect(controller.input.voice?.active == false && fake.stops == 1)
  fake.feeds.last?.yield(.transcript("spoken later"))
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.agent.active && model.navigator.input == "Prefilled")
  await controller.finish()
}

@MainActor @Test func aWaitingReturnStopsDictationStartedMeanwhileBeforeItRuns() async throws {
  let fake = FakeTranscriber()
  let (model, controller, root) = try await staleReturn(transcriber: { fake })
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "> B"
  controller.run()
  #expect(model.navigator.returnQueued)
  // The mic button, before the row Return waits for arrives.
  #expect(await listening(controller, fake))
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(controller.input.voice?.active == false && fake.stops == 1)
  fake.feeds.last?.yield(.transcript("spoken later"))
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.navigator.command?.id == "extension:echo" && model.navigator.input == "> B")
  await controller.finish()
}

@MainActor @Test func anOffscreenPanelIsReleasedWithItsScreens() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: nil)
  weak var released: PaletteController?
  weak var view: NSView?
  autoreleasepool {
    let controller = PaletteController(model: model, panel: RoutingPanel())
    controller.show(orderFront: false, listen: false)
    controller.panel.contentView?.layoutSubtreeIfNeeded()
    #expect(controller.panel.field != nil)
    controller.hide()
    released = controller
    view = controller.panel.contentView
  }
  #expect(await eventually { released == nil && view == nil })
  await model.finish()
}

@MainActor @Test func aPatternStillRunningHoldsAskAgentAndAnUntouchedReturnForItsRows() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  let surface = RecordingSurface(wrapping: controller)
  model.navigator.surface = surface
  var lists: [[String]] = []
  surface.onDraw = { lists.append(model.navigator.results.map(\.provider)) }
  model.navigator.input = "> B"
  // The list for what is typed comes after the hold, without Ask agent while the pattern runs.
  #expect(await eventually { !model.root.isSearching })
  #expect(!model.navigator.results.contains { $0.provider == "agent" || $0.row.id == "fallback" })
  #expect(model.navigator.awaitsPattern)
  controller.run()
  #expect(model.navigator.returnQueued && model.navigator.command == nil)
  try release(root, "echo")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(model.navigator.command?.id == "extension:echo" && !model.agent.active)
  #expect(lists.allSatisfy { !$0.contains("agent") })
  controller.hide()
  await model.finish()
}

@MainActor @Test func cmdReturnAsksWhileAPatternIsStillRunning() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "> B"
  #expect(await eventually { !model.root.isSearching })
  model.navigator.askAgent()
  #expect(model.agent.active && model.agent.question == "> B")
  try release(root, "echo")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

@MainActor @Test func aPatternThatAnswersNothingBringsAskAgentBackForReturn() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "> E"
  await model.navigator.settled()
  #expect(model.navigator.results.first?.provider == "agent" && !model.navigator.awaitsPattern)
  controller.run()
  #expect(!model.navigator.returnQueued && model.agent.active && model.agent.question == "> E")
  controller.hide()
  await model.finish()
}
