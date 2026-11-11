import AppKit
import SwiftUI
import Testing

@testable import WicketApp

@MainActor @Test func conversationKeepsDraftHistoryAndPendingDecisionAcrossHide() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  let escape = { controller.panel.route(voiceKey(53, "\u{1b}")) }
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.input = "First question"
  model.ask()
  #expect(await eventually { fake.running })
  fake.text("First answer")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.editInput("Draft follow-up")
  #expect(model.agent.answer == "First answer")
  let hidden = Date()
  model.dismiss()
  model.reopen(now: hidden.addingTimeInterval(299))
  #expect(model.input == "Draft follow-up" && model.agent.continuing)
  model.ask()
  #expect(!model.agent.continuing)
  #expect(await eventually { fake.running })
  #expect(model.agent.previous.first?.question == "First question")
  #expect(model.agent.previous.first?.answer == "First answer")
  model.editInput("Editable while running")
  model.ask()
  #expect(model.agent.question == "Draft follow-up" && model.input == "Editable while running")
  fake.ask()
  model.dismiss()
  model.reopen()
  #expect(model.agent.permissions.count == 1 && model.input == "Editable while running")
  for code: UInt16 in [36, 76] {
    #expect(controller.panel.route(voiceKey(code, "\r", .command, repeatKey: true)))
    #expect(model.agent.permissions.count == 1 && fake.decisions.isEmpty)
  }
  #expect(escape() && model.agent.permissions.isEmpty && model.agent.busy)
  #expect(fake.decisions.last.map { $0.id == .number(1) && !$0.allow } == true)
  #expect(escape())
  #expect(await eventually { !model.agent.busy })
  #expect(model.agent.active && model.agent.previous.count == 1)
  #expect(escape() && !model.agent.active && model.agent.previous.isEmpty)
  model.input = "root draft"
  #expect(escape() && model.input.isEmpty)
  #expect(escape() && !controller.panel.isVisible)
  model.ask()
  #expect(!model.agent.active)
  await model.finish()
}

@MainActor @Test func hideAndCompletionEachExtendConversationRetention() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = AgentSession(folder: root)
  try await finishTurn(session, "Q", "A")
  let later = Date().addingTimeInterval(600)
  session.hidden(now: later)
  session.reopen(now: later.addingTimeInterval(299))
  #expect(session.active)
  session.reopen(now: later.addingTimeInterval(301))
  #expect(!session.active)
  let fake = FakeAgent()
  session.connect = { _, _, _ in fake }
  session.retention = 5
  session.ask("Long running", settings: .init())
  #expect(await eventually { fake.running })
  session.hidden(now: .distantPast)
  session.reopen(now: .distantFuture)
  #expect(session.busy)
  fake.end()
  #expect(await eventually { !session.busy })
  session.reopen()
  #expect(session.active)
  session.reopen(now: Date().addingTimeInterval(10))
  #expect(!session.active)
  await session.shutdown()
}

@Test func confirmationUsesAgentStatedActionAndFullDetails() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appending(path: "working")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape"), withDestinationURL: root)
  func content(_ kind: String, path: String) -> ConfirmationContent {
    .agent(
      AgentPermission(
        id: .number(1), title: "Update weather", kind: AgentPermission.Kind(rawValue: kind)!,
        paths: path.isEmpty ? [] : [path],
        raw: .object("file_path", .string(path), "command", .string("full command"))), name: "Claude",
      folder: folder)
  }
  let routine = content("edit", path: folder.appending(path: "extensions/weather/main.py").path)
  #expect(routine.title == "Allow Claude to edit files?" && routine.consequence == nil)
  #expect(routine.details.contains("full command") && routine.details.contains("main.py"))
  #expect(content("delete", path: "/tmp/working/old.py").allow == "Allow deletion")
  #expect(content("read", path: "/tmp/outside/file").consequence == "Reaches outside the working folder.")
  #expect(content("read", path: "extensions/weather/main.py").consequence == nil)
  #expect(content("read", path: "escape/file").consequence == "Reaches outside the working folder.")
  try Data().write(to: root.appending(path: "file"))
  #expect(content("read", path: "escape/file").consequence == "Reaches outside the working folder.")
  #expect(content("read", path: "escape/working/inside").consequence == nil)
  #expect(content("read", path: "escape/../outside").consequence == "Reaches outside the working folder.")
  #expect(content("execute", path: "").consequence == "Runs a command without reported file locations.")
  #expect(content("read", path: "").consequence == nil)
  #expect(content("execute", path: "extensions/weather/main.py").consequence == nil)
}

@Test func textSizesRoundTripAndGrowRowsWithoutChangingInput() throws {
  #expect(try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8)).textSize == .medium)
  for size in Configuration.TextSize.allCases {
    var config = Configuration()
    config.textSize = size
    #expect(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)).textSize == size)
    #expect(size.points == ["small": 13, "medium": 15, "large": 17, "larger": 19][size.rawValue])
    let expected = CGFloat(3 * (size.rowHeight + 2) + 18)
    #expect(PaletteLayout.rowsHeight(3, rowHeight: size.rowHeight) == expected)
  }
  #expect(PaletteLayout.search == 56)
}

@MainActor @Test func liveTextSizeReachesTheExistingCanvasAndExpiredDraftReturnsToSearch() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  try await finishTurn(model.agent, "Question", "Answer")
  let controller = PaletteController(model: model)
  model.store.update { $0.voice.enabled = false }
  controller.show(orderFront: false, listen: false)
  let frame = controller.panel.frame
  model.conversationHeaderHeight += 100
  #expect(controller.panel.frame.height == frame.height + 100)
  #expect(controller.panel.frame.maxY == frame.maxY)
  model.store.update { $0.textSize = .larger }
  #expect(controller.renderer.textSize == .larger)
  model.input = "Keep temporarily"
  model.dismiss()
  model.reopen(now: Date().addingTimeInterval(301))
  #expect(!model.agent.active && model.input.isEmpty && model.command == nil)
  await model.finish()
}

@MainActor @Test func hiddenPermissionsExpireWithoutReopeningAndReopenCancelsTheDeadline() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = AgentSession(folder: root)
  let fake = FakeAgent()
  session.connect = { _, _, _ in fake }
  session.retention = 0.05
  session.ask("Permission", settings: .init())
  #expect(await eventually { fake.running })
  fake.ask()
  fake.ask()
  session.hidden()
  #expect(session.busy && session.permissions.count == 2)
  #expect(await eventually { session.permissions.isEmpty })
  #expect(fake.decisions.count == 2 && fake.decisions.allSatisfy { !$0.allow })
  fake.ask()
  session.hidden()
  session.reopen()
  try await Task.sleep(for: .milliseconds(100))
  #expect(session.permissions.count == 1 && fake.decisions.count == 2)
  session.hidden()
  session.reopen(now: Date().addingTimeInterval(1))
  #expect(session.permissions.isEmpty && fake.decisions.count == 3)
  fake.ask()
  session.hidden()
  session.decide(false)
  fake.end()
  #expect(await eventually { !session.busy })
  // A later turn must show its actual completion or error after a hidden conversation.
  session.ask("Next", settings: .init())
  #expect(!session.continuing)
  #expect(await eventually { fake.running })
  fake.ask()
  try await Task.sleep(for: .milliseconds(100))
  #expect(session.permissions.count == 1 && fake.decisions.count == 4)
  session.decide(false)
  fake.end(cancelled: true)
  #expect(await eventually { !session.busy })
  #expect(session.status == "Cancelled" && !session.continuing)
  await session.shutdown()
}

@MainActor @Test func previousAnswersKeepOnlyTenTurns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = AgentSession(folder: root)
  // One fake per turn: a finished turn stops its connection in the background, which would
  // otherwise clear the next turn's `running` on a shared fake.
  for number in 0..<13 { try await finishTurn(session, "Question \(number)", "Answer \(number)") }
  #expect(session.previous.count == 10 && session.previous.first?.question == "Question 2")
  #expect(session.previous.last?.answer == "Answer 11" && session.answer == "Answer 12")
  await session.shutdown()
}

@MainActor @Test func longConfirmationTextStaysBounded() async throws {
  _ = NSApplication.shared
  let content = ConfirmationContent(
    title: String(repeating: "Long extension name\n", count: 100),
    body: String(repeating: "Long action\n", count: 100), summary: ["/path/command", "Changed file"],
    details: "Full details", consequence: "Review this action.")
  for size in Configuration.TextSize.allCases {
    let view = NSHostingView(
      rootView: ConfirmationView(content: content, size: size, decide: { _ in }).frame(width: 640))
    #expect(view.fittingSize.height < 560)
  }
}

@MainActor @Test func aHiddenConversationOverAnExtensionDetailLetsTheRendererRelease() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, fields: ["command": ["/usr/bin/python3", "show.py"]])
  try Data(
    "import json,sys; json.load(sys.stdin); print(json.dumps({'type':'detail','body':'Extension detail'}))"
      .utf8
  ).write(to: ext.appending(path: "show.py"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.renderer.releaseDelay = .milliseconds(200)
  controller.show(orderFront: false, listen: false)
  model.input = "test"
  await model.settled()
  #expect(model.enterSelected())
  await model.settled()
  #expect(model.detailBody == "Extension detail" && controller.renderer.page != nil)
  // Ask the agent from the detail, then hide while it works.
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.ask("Explain this")
  #expect(await eventually { fake.running })
  controller.hide()
  fake.text("Still working")
  try await Task.sleep(for: .milliseconds(100))
  fake.text(" on it")
  #expect(await eventually { controller.renderer.page == nil })
  controller.renderer.release()
  await model.finish()
}
