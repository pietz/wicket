import Foundation
import Synchronization
import Testing

@testable import WicketApp

// Manifest `contract` and `permissions`, and Wicket's permission gate, with the system's permission state
// faked: no test touches TCC.

/// Stands in for macOS: Calendar can be asked for until granted, Accessibility only granted by hand.
@MainActor private final class FakePermissions {
  nonisolated private let grants = Mutex<Set<Permission>>([])
  var granted: Set<Permission> {
    get { grants.withLock { $0 } }
    set { grants.withLock { $0 = newValue } }
  }
  var asked: [Permission] = []
  var permissions: Permissions {
    Permissions(
      status: { [self] permission in
        grants.withLock { $0.contains(permission) } ? .granted : permission == .calendar ? .askable : .denied
      },
      request: { [self] in
        asked.append($0)
        if $0 == .calendar { granted.insert($0) }
      })
  }
}

/// An extension that declares `permissions` and logs each request it gets to `requests`. Window-style move items are
/// hidden runs, as the window commands are.
@MainActor private func gated(
  _ root: URL, _ permissions: [String], fields: [String: Any] = [:]
) async throws -> (LauncherModel, FakePermissions, RecordingSurface) {
  var manifest: [String: Any] = [
    "name": "Gated", "permissions": permissions,
    "items": [
      [
        "id": "left", "title": "Left",
        "actions": [["type": "run", "action": "left", "hidden": true]],
      ]
    ],
  ]
  manifest.merge(fields) { _, value in value }
  _ = try extensionFolder(
    root, name: "gated",
    script: """
      line=$(cat); echo "$line" >> "\(root.path)/requests"
      case "$line" in *'"action"'*) exit;; esac
      echo '{"items":[{"id":"ran","title":"Ran","actions":[]}]}'
      """,
    fields: manifest)
  let model = LauncherModel.testing(in: root)
  let fake = FakePermissions()
  model.extensions.permissions = fake.permissions
  model.store.start(watching: false)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  return (model, fake, surface)
}
private func requests(_ root: URL) -> [ProviderRequest] {
  let log = (try? String(contentsOf: root.appending(path: "requests"), encoding: .utf8)) ?? ""
  return log.split(separator: "\n").compactMap {
    try? JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8))
  }
}

@MainActor @Test(arguments: [false, true])
func missingGrantsStayOffTheEmptyRoot(compact: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, surface) = try await gated(root, ["accessibility", "calendar"], fields: ["match": "^$"])
  model.store.update { $0.resultsOnlyWhenTyping = compact }
  model.reopen()
  model.navigator.refresh()
  await model.navigator.settled()

  #expect(surface.presentation.showsCard != compact)
  #expect(!surface.presentation.rows.isEmpty && !Permissions.isGate(surface.presentation.rows))
  #expect(!surface.presentation.rows.contains { $0.row.id.hasPrefix("permission:") })
  #expect(requests(root).isEmpty && fake.asked.isEmpty)
  await model.finish()
}

@MainActor @Test(arguments: [false, true], [false, true])
func anUnresolvedHotkeyShowsItsOwnProblem(compact: Bool, hasRepair: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  if hasRepair {
    _ = try extensionFolder(root, name: "calendar", fields: ["contract": 0])
  }
  let (model, fake, surface) = try await gated(root, ["accessibility"])
  model.store.update { $0.resultsOnlyWhenTyping = compact }
  model.navigator.refresh()
  await model.navigator.settled()
  surface.shown = false
  surface.showing = { arriving in
    model.reopen()
    arriving()
  }

  model.press(HotkeyTarget(target: "extension:calendar"))
  await model.navigator.settled()
  #expect(surface.shows == 1)
  #expect(surface.presentation.footerMessage == "No extension named calendar")
  #expect(surface.presentation.showsCard == (!compact || hasRepair))
  if hasRepair {
    let repair = try #require(surface.presentation.selected)
    #expect(repair.provider == "extension:calendar" && repair.row.id == "discovery-error")
  } else if compact {
    #expect(surface.presentation.pillStatus == "No extension named calendar")
  }
  #expect(!surface.presentation.rows.contains { $0.row.id.hasPrefix("permission:") })
  #expect(requests(root).isEmpty && fake.asked.isEmpty)
  await model.finish()
}

@Test func aNewerContractNeedsANewerWicketInsteadOfARepair() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Keys this Wicket does not know are the newer contract's, not misspellings.
  _ = try extensionFolder(root, name: "future", fields: ["contract": 3, "widgets": ["clock"]])
  _ = try extensionFolder(root, name: "current", fields: ["contract": 2, "permissions": ["calendar"]])
  _ = try extensionFolder(root, name: "zero", fields: ["contract": 0])
  _ = try extensionFolder(root, name: "camera", fields: ["permissions": ["camera"]])
  _ = try extensionFolder(root, name: "twice", fields: ["permissions": ["calendar", "calendar"]])
  _ = try extensionFolder(
    root, name: "listonly",
    fields: ["command": NSNull(), "items": [], "permissions": ["calendar"]])
  let (commands, problems, _) = ExtensionHost.discover(root.appending(path: "extensions"), bundled: nil)
  #expect(commands["extension:current"]?.manifest.permissions == [.calendar])
  let future = try #require(problems["extension:future"])
  #expect(
    future.detail.contains("needs a newer Wicket") && future.detail.contains("contract 3")
      && !future.detail.contains("Invalid"))
  for broken in ["zero", "camera", "twice", "listonly"] {
    #expect(problems["extension:" + broken]?.detail.contains("Invalid wicket.json") == true, "\(broken)")
  }
  #expect(problems["extension:camera"]?.detail.contains("accessibility, calendar") == true)
  // At the root it says so, and leads to Settings, where Wicket updates, rather than to the agent.
  let rows = Ranking.compose(
    query: "", names: [], patterns: [:], extensions: [:],
    problems: ["extension:future": future, "extension:zero": problems["extension:zero"]!],
    usage: UsageStore()
  ).results
  let newer = try #require(rows.first { $0.provider == "extension:future" })
  #expect(newer.row.title == "extension:future needs a newer Wicket")
  #expect(newer.row.actions.map(\.kind) == [.run(Address(extensionName: "settings"))])
  #expect(rows.first { $0.provider == "extension:zero" }?.row.title == "extension:zero needs repair")
}

/// Entering a command whose permission is missing runs nothing and shows Wicket's row; allowing asks
/// macOS from Wicket and then sends the request the gate held back, as it was.
@MainActor @Test func aMissingPermissionShowsWicketsRowAndAllowingRunsTheRequest() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, surface) = try await gated(root, ["calendar"])
  model.store.update { $0.resultsOnlyWhenTyping = true }
  await model.navigator.settled()
  model.navigator.go(Address(extensionName: "gated", input: "today"), submitted: true)
  await model.navigator.settled()
  #expect(requests(root).isEmpty && fake.asked.isEmpty)
  let gate = try #require(model.navigator.results.first)
  #expect(model.navigator.results.count == 1 && gate.row.title == "Allow Calendar for Wicket")
  #expect(surface.presentation.showsCard && surface.presentation.selected?.id == gate.id)
  #expect(gate.row.subtitle == "Gated needs it")

  model.navigator.activate(gate.row.actions[0], from: gate)
  await model.navigator.settled()
  #expect(fake.asked == [.calendar])
  let request = try #require(requests(root).first)
  #expect(requests(root).count == 1 && request.input == "today" && request.submitted)
  #expect(model.navigator.command?.id == "extension:gated" && model.navigator.results.first?.row.id == "ran")
  await model.finish()
}

/// Refused once, Calendar can no longer be asked for inline: the row opens its pane instead.
@MainActor @Test func aRefusedCalendarOpensItsPane() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _, _) = try await gated(root, ["calendar"])
  model.extensions.permissions.status = { _ in .denied }
  model.navigator.go(Address(extensionName: "gated"), submitted: true)
  await model.navigator.settled()
  let gate = try #require(model.navigator.results.first)
  #expect(gate.row.actions.map(\.kind) == [.open(Permission.calendar.pane)] && requests(root).isEmpty)
  await model.finish()
}

/// Typing at the root never asks for a permission and never runs a program that lacks one: its pattern
/// shows nothing until the permission is there.
@MainActor @Test func aPatternMissingAPermissionRunsNothingAtTheRoot() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, _) = try await gated(root, ["calendar"], fields: ["match": "^agenda"])
  model.navigator.editInput("agenda")
  await model.navigator.settled()
  #expect(requests(root).isEmpty && fake.asked.isEmpty)
  #expect(!model.navigator.results.contains { $0.provider == "extension:gated" && $0.row.id == "ran" })
  fake.granted = [.calendar]
  model.navigator.editInput("agenda ")
  await model.navigator.settled()
  #expect(requests(root).count == 1 && fake.asked.isEmpty)
  #expect(model.navigator.results.contains { $0.provider == "extension:gated" && $0.row.id == "ran" })
  await model.finish()
}

/// A hidden run from a hotkey with the panel hidden, as a window command's: without the permission it does
/// not run, and the panel opens on Wicket's row instead of nothing happening.
@MainActor @Test func aHiddenRunMissingAPermissionShowsThePanelOnWicketsRow() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _, surface) = try await gated(root, ["accessibility"])
  model.store.update { $0.resultsOnlyWhenTyping = true }
  await model.navigator.settled()
  surface.shown = false
  model.press(HotkeyTarget(target: "extension:gated", item: "left"))
  await model.navigator.settled()
  #expect(requests(root).isEmpty && surface.shows == 1 && !surface.effects.contains(.hide))
  #expect(model.navigator.command?.id == "extension:gated")
  let gate = try #require(model.navigator.results.first)
  #expect(gate.row.title == "Allow Accessibility for Wicket")
  #expect(surface.presentation.showsCard && surface.presentation.selected?.id == gate.id)
  #expect(gate.row.actions.map(\.kind) == [.open(Permission.accessibility.pane)])
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func aHiddenHotkeyShowsAnActionablePermissionOverAConversation(kept: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _, surface) = try await gated(root, ["accessibility"])
  try await finishTurn(model, "Why?", "Because.")
  let navigator = model.navigator
  let draft = "One more question"
  navigator.editInput(draft)
  surface.showing = { arriving in
    model.reopen()
    arriving()
    model.agent.seen()
  }
  if kept {
    navigator.dismiss()
    surface.shown = false
  }

  let hotkey = HotkeyTarget(target: "extension:gated", item: "left")
  model.press(hotkey)
  await navigator.settled()
  let gate = try #require(surface.presentation.selected)
  #expect(gate.row.title == "Allow Accessibility for Wicket")
  #expect(surface.presentation.actionsTitle == "Gated" && surface.presentation.rows == [gate])
  #expect(surface.presentation.agent?.question == "Why?" && navigator.input == draft)
  #expect(surface.shows == (kept ? 1 : 0) && surface.effects.isEmpty && requests(root).isEmpty)

  #expect(navigator.escape())
  #expect(surface.presentation.actionsTitle == nil && surface.presentation.agent?.question == "Why?")
  #expect(navigator.page?.source.contains("Because.") == true && navigator.input == draft)

  model.press(hotkey)
  navigator.run()
  await navigator.settled()
  let action = try #require(gate.row.actions.first)
  #expect(action.kind == .open(Permission.accessibility.pane))
  #expect(surface.effects == [.run(action, from: nil)] && requests(root).isEmpty)
  #expect(surface.presentation.actionsTitle == nil && surface.presentation.agent?.question == "Why?")
  #expect(navigator.input == draft)
  await model.finish()
}

/// Allowed from the gate, a hidden run is sent again hidden, and its success shows nothing.
@MainActor @Test func aHiddenRunAllowedFromTheGateRunsHidden() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _, surface) = try await gated(root, ["calendar"])
  surface.shown = false
  model.press(HotkeyTarget(target: "extension:gated", item: "left"))
  await model.navigator.settled()
  let gate = try #require(model.navigator.results.first)
  #expect(model.navigator.selected?.id == gate.id)
  guard case .grant(.calendar, let address) = gate.row.actions[0].kind else {
    Issue.record("The gate does not ask for Calendar")
    return
  }
  #expect(address.hidden && address.action == "left")
  model.navigator.activate(gate.row.actions[0], from: gate)
  await model.navigator.settled()
  let request = try #require(requests(root).first)
  #expect(requests(root).count == 1 && request.submitted && request.action == "left")
  #expect(surface.effects.contains(.hide))
  await model.finish()
}

/// In a submit command, where items otherwise wait for an arrow key, Return on the gate allows rather
/// than sending the request again to the same gate. After an edit, Return first sends the edited request,
/// so the grant follows that one.
@MainActor @Test func returnOnTheGateInASubmitCommandAllows() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, _) = try await gated(root, ["calendar"], fields: ["submit": true])
  model.navigator.go(Address(extensionName: "gated"))
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "permission:calendar")
  model.navigator.editInput("today")
  #expect(model.navigator.selected?.row.id == "submit")
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(requests(root).isEmpty && model.navigator.selected?.row.id == "permission:calendar")
  model.activateReturn()
  await model.navigator.settled()
  #expect(fake.asked == [.calendar] && requests(root).map(\.input) == ["today"])
  #expect(model.navigator.results.first?.row.id == "ran")
  await model.finish()
}

/// Headless cannot ask macOS: a run held back by a missing permission is an error naming it, not the
/// gate's rows printed as if the program had answered.
@MainActor @Test func headlessRefusesARunMissingAPermission() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, _) = try await gated(root, ["calendar", "accessibility"])
  let command = try #require(model.extensions.commands["extension:gated"])
  let refusal = try #require(Headless.refusal(command, fake.permissions))
  let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(refusal))
  #expect(json["permissions"] == .array([.string("calendar"), .string("accessibility")]))
  #expect(
    json["error"].string
      == "Gated needs Calendar and Accessibility for Wicket: open it in the panel to allow it")
  fake.granted = [.calendar, .accessibility]
  #expect(Headless.refusal(command, fake.permissions)?.error == nil)
  await model.finish()
}

@MainActor @Test func anAgentDraftTakesReturnBeforeAnUnselectedPermissionGate() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, permissions, _) = try await gated(root, ["calendar"], fields: ["fields": []])
  let agent = FakeAgent()
  model.agent.connect = { _, _, _ in agent }
  model.navigator.go(Address(id: "gated"))
  await model.navigator.settled()
  #expect(model.navigator.selected?.row.id == "permission:calendar")
  #expect(model.navigator.presentation.commandPlaceholder == "Ask about Gated…")
  let question = "Why do you need access?"
  model.navigator.editInput(question)
  #expect(model.navigator.selection == nil && model.navigator.presentation.returnAsksAgent)

  model.navigator.move(1)
  #expect(model.navigator.selected?.row.id == "permission:calendar")
  #expect(model.navigator.returnAction?.label == "Allow Calendar Access")
  model.navigator.move(-1)
  #expect(model.navigator.selection == nil && model.activateReturn())
  #expect(await eventually { agent.running })
  #expect(agent.prompts.last?.text.contains(question) == true)
  #expect(permissions.asked.isEmpty && requests(root).isEmpty)
  await model.finish()
}

/// Replaying a permission-gated request restores the saved field set instead of merging fields filled
/// while the gate was visible.
@MainActor @Test func replayingAGatedRequestRestoresTheOriginalFields() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake, _) = try await gated(
    root, ["calendar"],
    fields: [
      "submit": true,
      "fields": [
        ["name": "query", "type": "text", "description": "Search query"],
        ["name": "days", "type": "number", "description": "Number of days"],
      ],
    ])
  model.navigator.go(Address(extensionName: "gated", fields: ["query": "today"]), submitted: true)
  await model.navigator.settled()
  #expect(requests(root).isEmpty && model.navigator.selected?.row.id == "permission:calendar")

  // Fill the previously empty optional field while the gate is up, then explicitly select the gate.
  model.navigator.setField("days", to: "7")
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.id == "permission:calendar")
  #expect(model.activateReturn())
  await model.navigator.settled()

  #expect(fake.asked == [.calendar])
  let request = try #require(requests(root).first)
  #expect(requests(root).count == 1 && request.submitted)
  #expect(request.fields == ["query": "today"])
  #expect(model.navigator.fieldValues["days"] == nil)
  await model.finish()
}
