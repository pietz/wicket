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
          ["type": "run", "title": "Delete", "arguments": ["delete": "two"]],
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
  #expect(model.actions(of: app) == [.open(file)])
  let found = Result(provider: "files", row: Row(id: "f", title: "F", actions: [.open(file), .reveal(file)]))
  #expect(model.actions(of: found).map(\.label) == ["Open", "Reveal in Finder"])
  // A command row and a host row add Set Hotkey…, and Remove Hotkey once one is set.
  model.input = "test"
  await model.settled()
  let command = try #require(model.results.first { $0.row.id == "command" })
  let target = HotkeyTarget(target: "extension:test")
  #expect(model.actions(of: command) == command.row.actions + [RowAction(.hotkey(target, record: true))])
  model.store.bind(try Shortcut("ctrl+option+t"), to: target)
  let remove = RowAction(.hotkey(target, record: false))
  #expect(model.actions(of: command).map(\.label) == ["Open", "Set Hotkey…", "Remove Hotkey"])
  #expect(model.actions(of: command).last == remove)
  #expect(model.activate(remove, from: command) && model.configuration.hotkeys.isEmpty)
  model.input = "settings"
  await model.settled()
  let settings = try #require(model.results.first { $0.provider == "settings" })
  #expect(model.actions(of: settings).map(\.label) == ["Open", "Set Hotkey…"])
  // Inside a command an item without an address is only its own actions.
  model.go(Address(id: "test"))
  await model.settled()
  #expect(model.actions(of: model.results[1]).map(\.label) == ["Copy", "Open", "Delete"])
  await model.finish()
}

@MainActor @Test func commandKListsTheSelectedRowsActionsAndEscapeReturns() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await printing(two, in: root)
  model.go(Address(id: "test"))
  await model.settled()
  // The footer offers ⌘K only for a row with more than Return.
  #expect(model.selected?.row.id == "one" && !model.offersActions)
  model.move(1)
  let item = try #require(model.selected)
  #expect(item.row.id == "two" && model.offersActions && model.sizedRows == 2)
  model.toggleActions()
  #expect(model.actionsTitle == "Two" && !model.offersActions && model.sizedRows == 3)
  #expect(model.results.map(\.row.title) == ["Copy", "Open", "Delete"])
  #expect(model.results.allSatisfy { $0.row.actions.count == 1 })
  #expect(model.returnAction == .copy("2"))
  // Up from the first action stays in the panel.
  model.move(-1)
  model.move(1)
  #expect(model.returnAction?.label == "Open")
  // Escape returns with the selection intact; ⌘K again too.
  #expect(model.escape())
  #expect(model.actionsTitle == nil && model.selected?.row.id == "two" && model.sizedRows == 2)
  model.toggleActions()
  model.toggleActions()
  #expect(model.actionsTitle == nil && model.selected?.row.id == "two")
  // Return runs the chosen action for the row: here a run of its own extension, submitted.
  model.toggleActions()
  model.move(1)
  model.move(1)
  let picked = try #require(model.pick())
  #expect(picked.action.label == "Delete" && picked.from?.id == item.id && model.actionsTitle == nil)
  #expect(model.activate(picked.action, from: picked.from))
  await model.settled()
  let requests = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8)) }
  #expect(requests.last == ProviderRequest(input: "", arguments: ["delete": "two"], submitted: true))
  await model.finish()
}

@MainActor @Test func typingAndCommandReturnLeaveTheActionPanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await printing(two, in: root)
  model.go(Address(id: "test"))
  await model.settled()
  model.move(1)
  // ⌘Return keeps its meaning: it leaves the panel and asks about what is on screen, and Escape comes
  // back to the row.
  model.toggleActions()
  model.askAgent()
  #expect(model.actionsTitle == nil && model.agent.active && model.returnsOnEscape)
  #expect(model.escape() && !model.agent.active && model.selected?.row.id == "two")
  // Typing goes to the input as the field shows it: the panel's field was empty.
  model.input = "t"
  await model.settled()
  #expect(model.selected?.row.id == "two")
  model.toggleActions()
  model.editInput("w")
  #expect(model.actionsTitle == nil && model.input == "w")
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
  model.go(Address(id: "test"))
  await model.settled()
  // Nothing selected: the view's own actions, under the command's name.
  #expect(model.page != nil && model.selection == nil && model.offersActions)
  model.toggleActions()
  #expect(model.actionsTitle == "Test" && model.page != nil)
  #expect(model.results.map(\.row.title) == ["Copy", "Open"] && model.selectedTarget == nil)
  #expect(model.escape() && model.actionsTitle == nil && model.selection == nil)
  // A selected target: its detail and its action.
  model.move(1)
  #expect(model.selectedTarget == "#0" && model.offersActions)
  model.toggleActions()
  #expect(model.actionsTitle == "Tue" && model.results.map(\.row.title) == ["Show details", "Copy"])
  #expect(model.escape() && model.selectedTarget == "#0")
  // The header's Actions button lists the view's, and Escape keeps the target selected.
  model.toggleActions(model.viewRow)
  #expect(model.results.map(\.row.title) == ["Copy", "Open"])
  #expect(model.escape() && model.selectedTarget == "#0")
  // Show details from the panel opens the detail over the page, as Return on the target would.
  model.toggleActions()
  #expect(model.activateReturn() && model.inDetail && model.actionsTitle == nil)
  #expect(model.escape() && !model.inDetail && model.selectedTarget == "#0")
  await model.finish()
}

@MainActor @Test func anAgentsPermissionClosesTheActionPanelAndKeepsItClosed() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.input = "What is on today?"
  model.send()
  #expect(await eventually { fake.running })
  fake.text("Today.\n<row title=\"Tue\" copy=\"tue\">Rain</row>")
  #expect(await eventually { model.results.count == 1 })
  model.move(1)
  model.toggleActions()
  #expect(model.actionsTitle == "Tue" && model.results.map(\.row.title) == ["Show details", "Copy"])
  // The permission card must be seen: the panel goes, the target stays selected, ⌘K waits.
  fake.ask()
  #expect(model.actionsTitle == nil && model.selectedTarget == "#0")
  model.toggleActions()
  #expect(model.actionsTitle == nil)
  model.agent.decide(false)
  fake.end()
  await model.finish()
}
