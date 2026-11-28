import Foundation
import Testing

@testable import WicketApp

/// An extension named Test that prints `view` and logs each request to `requests` in `root`.
@MainActor private func printing(_ view: [String: Any], in root: URL) async throws -> LauncherModel {
  let json = String(decoding: try JSONSerialization.data(withJSONObject: view), as: UTF8.self)
  _ = try extensionFolder(
    root, script: "line=$(cat); echo \"$line\" >> \"\(root.path)/requests\"\nprintf '%s' '\(json)'",
    fields: ["name": "Test"])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  return model
}

/// Two items, the second with three actions.
private var two: [String: Any] {
  [
    "items": [
      ["id": "one", "title": "One", "actions": [["type": "copy", "text": "1"]]],
      [
        "id": "two", "title": "Two",
        "actions": [
          ["type": "copy", "text": "2"], ["type": "open", "url": "https://example.com"],
          ["type": "run", "title": "Delete", "fields": ["id": "two"], "action": "delete"],
        ],
      ],
    ]
  ]
}

@MainActor @Test func aRowsActionsAreItsOwnThenTheHosts() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await printing(two, in: root)
  // An app or a file has no address of its own: only what it carries.
  let file = URL(filePath: "/tmp/a.txt")
  let app = Result(provider: "apps", row: Row(id: "a", title: "A", actions: [.open(file)]))
  #expect(model.navigator.actions(of: app) == [.open(file)])
  let found = Result(provider: "files", row: Row(id: "f", title: "F", actions: [.open(file), .reveal(file)]))
  #expect(model.navigator.actions(of: found).map(\.label) == ["Open", "Reveal in Finder"])
  // A command row and a host row add Set Hotkey…, and Remove Hotkey once one is set.
  model.navigator.input = "test"
  await model.navigator.settled()
  let command = try #require(model.navigator.results.first { $0.row.id == "command" })
  let target = HotkeyTarget(target: "extension:test")
  #expect(
    model.navigator.actions(of: command) == command.row.actions + [RowAction(.hotkey(target, record: true))])
  model.store.bind(try Shortcut("ctrl+option+t"), to: target)
  let remove = RowAction(.hotkey(target, record: false))
  #expect(model.navigator.actions(of: command).map(\.label) == ["Open", "Set Hotkey…", "Remove Hotkey"])
  #expect(model.navigator.actions(of: command).last == remove)
  #expect(model.navigator.activate(remove, from: command) && model.configuration.hotkeys.isEmpty)
  model.navigator.input = "settings"
  await model.navigator.settled()
  let settings = try #require(model.navigator.results.first { $0.provider == "settings" })
  #expect(model.navigator.actions(of: settings).map(\.label) == ["Open", "Set Hotkey…"])
  // Inside a command an item without an address is only its own actions.
  model.navigator.go(Address(id: "test"))
  await model.navigator.settled()
  #expect(model.navigator.actions(of: model.navigator.results[1]).map(\.label) == ["Copy", "Open", "Delete"])
  await model.finish()
}

@MainActor @Test func commandKListsTheSelectedRowsActionsAndEscapeReturns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await printing(two, in: root)
  model.navigator.go(Address(id: "test"))
  await model.navigator.settled()
  // The footer offers ⌘K only for a row with more than Return.
  #expect(model.navigator.selected?.row.id == "one" && !model.navigator.offersActions)
  model.navigator.move(1)
  let item = try #require(model.navigator.selected)
  #expect(item.row.id == "two" && model.navigator.offersActions && model.navigator.sizedRows == 2)
  model.navigator.toggleActions()
  #expect(
    model.navigator.actionsTitle == "Two" && !model.navigator.offersActions && model.navigator.sizedRows == 3)
  #expect(model.navigator.results.map(\.row.title) == ["Copy", "Open", "Delete"])
  #expect(model.navigator.results.allSatisfy { $0.row.actions.count == 1 })
  #expect(model.navigator.returnAction == .copy("2"))
  // Up from the first action stays in the panel.
  model.navigator.move(-1)
  model.navigator.move(1)
  #expect(model.navigator.returnAction?.label == "Open")
  // Escape returns with the selection intact; ⌘K again too.
  #expect(model.navigator.escape())
  #expect(
    model.navigator.actionsTitle == nil && model.navigator.selected?.row.id == "two"
      && model.navigator.sizedRows == 2)
  model.navigator.toggleActions()
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == nil && model.navigator.selected?.row.id == "two")
  // Return runs the chosen action for the row: here a run of its own extension, submitted.
  model.navigator.toggleActions()
  model.navigator.move(1)
  model.navigator.move(1)
  let picked = try #require(model.navigator.pick())
  #expect(
    picked.action.label == "Delete" && picked.from?.id == item.id && model.navigator.actionsTitle == nil)
  #expect(model.navigator.activate(picked.action, from: picked.from))
  await model.navigator.settled()
  let requests = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8)) }
  #expect(
    requests.last == ProviderRequest(input: "", fields: ["id": "two"], action: "delete", submitted: true))
  await model.finish()
}

@MainActor @Test func typingAndCommandReturnLeaveTheActionPanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await printing(two, in: root)
  model.navigator.go(Address(id: "test"))
  await model.navigator.settled()
  model.navigator.move(1)
  // ⌘Return keeps its meaning: it leaves the panel and asks about what is on screen, and Escape comes
  // back to the row.
  model.navigator.toggleActions()
  model.navigator.askAgent()
  #expect(model.navigator.actionsTitle == nil && model.agent.active && model.navigator.returnsOnEscape)
  #expect(model.navigator.escape() && !model.agent.active && model.navigator.selected?.row.id == "two")
  // Typing goes to the input as the field shows it: the panel's field was empty.
  model.navigator.input = "t"
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "two")
  model.navigator.toggleActions()
  model.navigator.editInput("w")
  #expect(model.navigator.actionsTitle == nil && model.navigator.input == "w")
  await model.finish()
}

@MainActor @Test func onAPageCommandKListsTheTargetsActionsOrTheViews() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let page: [String: Any] = [
    "body": "## Week\n<row title=\"Tue\" copy=\"tue\">Rain</row>",
    "items": [["id": "radar", "title": "Radar", "actions": [["type": "copy", "text": "radar"]]]],
    "actions": [["type": "copy", "text": "week"], ["type": "open", "url": "https://example.com"]],
  ]
  let model = try await printing(page, in: root)
  model.navigator.go(Address(id: "test"))
  await model.navigator.settled()
  // Nothing selected: the view's own actions, under the command's name.
  #expect(model.navigator.page != nil && model.navigator.selection == nil && model.navigator.offersActions)
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == "Test" && model.navigator.page != nil)
  #expect(
    model.navigator.results.map(\.row.title) == ["Copy", "Open"] && model.navigator.selectedTarget == nil)
  #expect(model.navigator.escape() && model.navigator.actionsTitle == nil && model.navigator.selection == nil)
  // A selected target: its detail and its action.
  model.navigator.move(1)
  #expect(model.navigator.selectedTarget == "#0" && model.navigator.offersActions)
  model.navigator.toggleActions()
  #expect(
    model.navigator.actionsTitle == "Tue"
      && model.navigator.results.map(\.row.title) == ["Show details", "Copy"])
  #expect(model.navigator.escape() && model.navigator.selectedTarget == "#0")
  // The header's Actions button lists the view's, and Escape keeps the target selected.
  model.navigator.toggleActions(model.navigator.viewRow)
  #expect(model.navigator.results.map(\.row.title) == ["Copy", "Open"])
  #expect(model.navigator.escape() && model.navigator.selectedTarget == "#0")
  // Show details from the panel opens the detail over the page, as Return on the target would.
  model.navigator.toggleActions()
  #expect(model.activateReturn() && model.navigator.inDetail && model.navigator.actionsTitle == nil)
  #expect(model.navigator.escape() && !model.navigator.inDetail && model.navigator.selectedTarget == "#0")
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func returnAndCommandKCopyTheBodyOfASelectedRow(extensionPage: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let draft = "## Release notes\n\n" + String(repeating: "One **fix** shipped.\n\n", count: 60) + "The end."
  let body = "<row title=\"Draft\" copy-body=\"true\">\n\(draft)\n</row>"
  let model: LauncherModel
  if extensionPage {
    model = try await printing(["body": body], in: root)
    model.navigator.go(Address(id: "test"))
    await model.navigator.settled()
  } else {
    model = LauncherModel.testing(in: root)
    try await finishTurn(model, "Draft release notes", body)
  }
  let surface = RecordingSurface()
  let navigator = model.navigator
  navigator.surface = surface
  navigator.move(1)
  let target = try #require(navigator.selected)
  let copy = PaletteEffect.run(.copy(draft), from: target)
  #expect(navigator.offersActions)
  navigator.run()
  #expect(surface.count(copy) == 1 && !navigator.inDetail)

  navigator.toggleActions()
  #expect(navigator.results.map(\.row.title) == ["Copy", "Show details"])
  navigator.run()
  #expect(surface.count(copy) == 2 && navigator.actionsTitle == nil)

  navigator.toggleActions()
  navigator.move(1)
  navigator.run()
  #expect(navigator.inDetail && navigator.page?.source.hasPrefix("## Draft\n\n\(draft)") == true)
  #expect(navigator.escape() && navigator.selectedTarget == target.row.id)
  await model.finish()
}

@MainActor @Test func anAgentsPermissionClosesTheActionPanelAndKeepsItClosed() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.navigator.input = "What is on today?"
  model.navigator.send()
  #expect(await eventually { fake.running })
  fake.text("Today.\n<row title=\"Tue\" copy=\"tue\">Rain</row>")
  #expect(await eventually { model.navigator.results.count == 1 })
  model.navigator.move(1)
  model.navigator.toggleActions()
  #expect(
    model.navigator.actionsTitle == "Tue"
      && model.navigator.results.map(\.row.title) == ["Show details", "Copy"])
  // The permission card must be seen: the panel goes, the target stays selected, ⌘K waits.
  fake.ask()
  #expect(model.navigator.actionsTitle == nil && model.navigator.selectedTarget == "#0")
  model.navigator.toggleActions()
  #expect(model.navigator.actionsTitle == nil)
  model.agent.decide(false)
  fake.end()
  await model.finish()
}

@MainActor @Test(arguments: ["row", "tile"])
func actionFirstJoinsOnReturnAndClickAndKeepsDetailsInCommandK(tag: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = try #require(URL(string: "https://example.com/join"))
  let body = """
    <\(tag) title="Standup" open="\(url.absoluteString)" action="Join" action-first="true">Room 2</\(tag)>
    <row title="Notes" action-first="true">Project notes.</row>
    """
  let model = try await printing(["body": body], in: root)
  let navigator = model.navigator
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.move(1)
  let target = try #require(navigator.selected)
  let join = PaletteEffect.run(.open(url, title: "Join"), from: target)

  navigator.run()
  #expect(surface.count(join) == 1 && !navigator.inDetail)
  let revision = navigator.page?.targetRevision ?? navigator.pageTurn
  #expect(navigator.clickTarget(target.row.id, revision: revision))
  #expect(surface.count(join) == 2 && !navigator.inDetail)

  navigator.toggleActions()
  #expect(navigator.results.map(\.row.title) == ["Join", "Show details"])
  navigator.move(1)
  #expect(model.activateReturn() && navigator.inDetail)
  #expect(navigator.page?.source.contains("Room 2") == true)
  #expect(navigator.page?.targets.map(\.title) == ["Join"])
  #expect(navigator.escape())
  navigator.move(1)
  #expect(navigator.selected?.row.title == "Notes")
  #expect(navigator.returnAction?.label == "Show details")
  await model.finish()
}
