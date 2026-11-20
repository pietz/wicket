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

@MainActor @Test func aSelectedPatternResultRunsWhileAnotherPatternIsStillRunning() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  // A second pattern for the same input that answers only once released, after the first one's row.
  _ = try extensionFolder(
    root, name: "held",
    script: "cat >/dev/null\nwhile [ ! -e release ]; do sleep 0.01; done\necho '{\"items\":[]}'",
    fields: ["match": "^> "])
  model.store.update { $0.providers = [.init("extension:echo"), .init("extension:held")] }
  await model.extensions.reload()
  model.navigator.input = "> C"
  #expect(await eventually { model.navigator.selected?.row.title == "> C" })
  #expect(model.navigator.awaitsPattern)
  controller.run()
  #expect(!model.navigator.returnQueued)
  #expect(await eventually { model.navigator.command?.id == "extension:echo" })
  try release(root, "held")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

/// Two patterns for `go`: Alpha ranks first but answers only once released, Zulu answers at once.
@MainActor private func twoPatterns() async throws -> (LauncherModel, PaletteController, URL) {
  let (model, controller, root) = try await staleReturn()
  for (name, wait) in [("alpha", "while [ ! -e release ]; do sleep 0.01; done\n"), ("zulu", "")] {
    _ = try extensionFolder(
      root, name: name,
      script: "cat >/dev/null\n" + wait
        + "echo '{\"items\":[{\"id\":\"r\",\"title\":\"\(name) result\",\"actions\":[{\"type\":\"run\"}]}]}'",
      fields: ["match": "^go"])
  }
  model.store.update { $0.providers = [.init("extension:alpha"), .init("extension:zulu")] }
  await model.extensions.reload()
  return (model, controller, root)
}

@MainActor @Test func aReturnPressedBeforeTheRowsWaitsForAHigherRankedPattern() async throws {
  let (model, controller, root) = try await twoPatterns()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "go"
  controller.run()
  #expect(model.navigator.returnQueued)
  // Zulu's row arrives and is selected, but Alpha, still running, ranks above it: the Return waits.
  #expect(await eventually { model.navigator.selected?.provider == "extension:zulu" })
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.navigator.returnQueued && model.navigator.command == nil)
  try release(root, "alpha")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(model.navigator.command?.id == "extension:alpha")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

@MainActor @Test func aReturnOnAVisiblePatternResultRunsItThoughAHigherRankedOneIsRunning() async throws {
  let (model, controller, root) = try await twoPatterns()
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.input = "go"
  #expect(await eventually { model.navigator.selected?.provider == "extension:zulu" })
  controller.run()
  #expect(!model.navigator.returnQueued)
  #expect(await eventually { model.navigator.command?.id == "extension:zulu" })
  try release(root, "alpha")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

@MainActor @Test func aCommandRowOfAPatternThatAnsweredNothingWaitsForAnotherPattern() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "needle", fields: ["match": "^needle"])
  _ = try extensionFolder(
    root, name: "held",
    script: "cat >/dev/null\nwhile [ ! -e release ]; do sleep 0.01; done\necho '{\"items\":[]}'",
    fields: ["match": "^needle"])
  model.store.update { $0.providers = [.init("extension:needle"), .init("extension:held")] }
  await model.extensions.reload()
  model.navigator.input = "needle"
  // Needle answered nothing, so its row is its command's, not a result: Return waits for Held.
  #expect(await eventually { model.navigator.selected?.row.id == "command" })
  #expect(model.navigator.selected?.provider == "extension:needle" && model.navigator.awaitsPattern)
  controller.run()
  #expect(model.navigator.returnQueued && model.navigator.command == nil)
  try release(root, "held")
  #expect(await eventually(within: .seconds(3)) { model.navigator.command != nil })
  #expect(model.navigator.command?.id == "extension:needle")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

/// Spotlight that delivers one batch only when the test sends it.
private final class HeldFiles: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<[FileHit]>.Continuation?
  private let home: String
  init(home: String = "/Users/me") { self.home = home }
  var provider: FilesProvider {
    FilesProvider(
      search: { _, _, _ in
        AsyncStream { continuation in self.lock.withLock { self.continuation = continuation } }
      }, home: home, scopes: { [self.home] }, debounce: .zero)
  }
  var started: Bool { lock.withLock { continuation != nil } }
  func send(_ path: String) {
    lock.withLock { continuation }?.yield([FileHit(path: path, isFolder: false)])
  }
}

@MainActor @Test func returnAfterAFailedPatternDoesNothingAndALateFileNeverRuns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = HeldFiles()
  _ = try extensionFolder(root, name: "broken", script: "exit 1", fields: ["match": "^needle"])
  let model = LauncherModel(
    files: files.provider, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:broken"), .init("files")] }
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.input = "needle"
  #expect(await eventually { model.navigator.results.contains { $0.row.id == "error" } })
  #expect(model.navigator.selected?.provider == "agent" && files.started)
  // Return twice on Ask agent after the failure: neither asks nor waits for anything.
  model.navigator.run()
  model.navigator.run()
  #expect(!model.navigator.returnQueued && !model.agent.active)
  // The footer offers ⌘↩ alone, not a Return that does nothing.
  #expect(model.navigator.presentation.refusesReturn)
  files.send("/Users/me/needle.txt")
  #expect(await eventually { model.navigator.selected?.provider == "files" })
  try await Task.sleep(for: .milliseconds(50))
  #expect(surface.effects.isEmpty && !model.agent.active)
  // A pick still runs, and ⌘↩ still asks.
  model.navigator.askAgent()
  #expect(model.agent.active && model.agent.question == "needle")
  await model.finish()
}

/// A Return pressed before the rows waits for the pattern; once the pattern fails, the file Spotlight
/// delivered, before or after the failure, is not what the Return was for: nothing runs. A fresh press on
/// the file, now seen, opens it.
@MainActor @Test(arguments: [true, false])
func anEarlyReturnHeldForAPatternThatFailsOpensNoFile(fileFirst: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "needle.txt")
  try Data("x".utf8).write(to: file)
  let files = HeldFiles(home: root.path)
  _ = try extensionFolder(
    root, name: "broken", script: "cat >/dev/null\nwhile [ ! -e release ]; do sleep 0.01; done\nexit 1",
    fields: ["match": "^needle"])
  let model = LauncherModel(
    files: files.provider, history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    bundled: nil)
  model.agent.connect = { _, _, _ in FakeAgent() }
  model.store.update { $0.providers = [.init("extension:broken"), .init("files")] }
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.input = "needle"
  model.navigator.run()
  #expect(model.navigator.returnQueued)
  #expect(await eventually { files.started })
  let fileShown = { model.navigator.results.first?.provider == "files" }
  if fileFirst {
    files.send(file.path)
    #expect(await eventually { fileShown() })
    #expect(model.navigator.returnQueued && surface.effects.isEmpty)
  }
  try release(root, "broken")
  #expect(await eventually { model.navigator.results.contains { $0.row.id == "error" } })
  if !fileFirst {
    files.send(file.path)
    #expect(await eventually { fileShown() })
  }
  try await Task.sleep(for: .milliseconds(50))
  #expect(!model.navigator.returnQueued && surface.effects.isEmpty && !model.agent.active)
  model.navigator.select(model.navigator.results.first?.id)
  model.navigator.run()
  #expect(surface.effects.count == 1 && !model.agent.active)
  await model.finish()
}

/// Filling the selected command row's argument picks that row: Return runs it with the draft, though a
/// pattern that would rank above it is still running.
@MainActor @Test func returnFromAFilledArgumentRunsItsCommandWhileAPatternRuns() async throws {
  let (model, controller, root) = try await staleReturn()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "notes", fields: ["arguments": [["name": "topic"]]])
  _ = try extensionFolder(
    root, name: "held",
    script: "cat >/dev/null\nwhile [ ! -e release ]; do sleep 0.01; done\n" + answering("held result"),
    fields: ["match": "^notes"])
  model.store.update { $0.providers = [.init("extension:notes"), .init("extension:held")] }
  await model.extensions.reload()
  model.navigator.input = "notes"
  #expect(await eventually { model.navigator.selected?.provider == "extension:notes" })
  #expect(model.navigator.selected?.row.id == "command" && model.navigator.awaitsPattern)
  #expect(model.navigator.moveFocus(1) && model.navigator.focusedArgument == "topic")
  model.navigator.setArgument("topic", to: "travel")
  controller.run()
  #expect(!model.navigator.returnQueued)
  #expect(await eventually { model.navigator.command?.id == "extension:notes" })
  #expect(model.navigator.argumentValues == ["topic": "travel"])
  try release(root, "held")
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}
