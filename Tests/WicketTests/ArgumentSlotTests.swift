import AppKit
import Testing

@testable import WicketApp

@Test func tabMovesBetweenSlotsOnlyWhereThereAreSlots() {
  func decide(_ modifiers: Shortcut.Modifiers, slots: Bool, permission: Bool = false, marked: Bool = false)
    -> PaletteKeyAction
  {
    PaletteKeyAction.decide(
      keyCode: 48, characters: "\t", modifiers: modifiers, hasMarkedText: marked,
      permissionPending: permission, hasArguments: slots)
  }
  #expect(decide([], slots: true) == .focus(1) && decide(.shift, slots: true) == .focus(-1))
  // Without slots, in the confirmation card and during composition, Tab stays AppKit's.
  #expect(decide([], slots: false) == .passThrough && decide(.shift, slots: false) == .passThrough)
  #expect(decide([], slots: true, permission: true) == .passThrough)
  #expect(decide([], slots: true, marked: true) == .passThrough)
  #expect(decide(.control, slots: true) == .passThrough)
}

/// The panel's real fields, routed without a window on screen: Tab order, voice, typing, arrows,
/// Return with the filled slots, Escape and focus returning to the input when the slots go away.
@MainActor @Test func slotsTakeTheKeysInOrderAndGiveThemBackToTheInput() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "caffeinate",
    fields: ["arguments": [["name": "hours", "placeholder": "hours"], ["name": "minutes"]]])
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  model.store.update { $0.voice.enabled = true }
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  let panel = controller.panel
  controller.show(orderFront: false, listen: false)
  let input = try #require(panel.input)
  func editing(_ field: NSTextField?) -> Bool {
    guard let editor = field?.currentEditor() else { return false }
    return panel.firstResponder === editor
  }
  func slot(_ label: String) -> NSTextField? {
    func find(_ view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field !== input, field.placeholderString == label { return field }
      return view.subviews.lazy.compactMap(find).first
    }
    return find(panel.contentView!)
  }
  func settle() async {
    await model.settled()
    panel.contentView?.layoutSubtreeIfNeeded()
  }
  model.editInput("caff")
  await settle()
  #expect(model.declaredArguments.map(\.name) == ["hours", "minutes"] && editing(input))
  let hours = try #require(slot("hours"))
  #expect(hours.accessibilityLabel() == "hours" && slot("minutes") != nil)

  // Tab: input, hours, minutes, input; Shift+Tab goes back.
  #expect(panel.route(voiceKey(48, "\t")))
  await settle()
  #expect(model.focusedArgument == "hours" && editing(hours))
  #expect(panel.route(voiceKey(48, "\t")))
  await settle()
  #expect(model.focusedArgument == "minutes" && editing(slot("minutes")))
  #expect(panel.route(voiceKey(48, "\t")))
  await settle()
  #expect(model.focusedArgument == nil && editing(input))
  #expect(panel.route(voiceKey(48, "\t", .shift)))
  await settle()
  #expect(model.focusedArgument == "minutes")

  // A key in a slot stops voice capture first.
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  #expect(await eventually { model.voice?.state == .listening })
  #expect(panel.route(voiceKey(48, "\t", .shift)))
  #expect(model.voice?.state == .idle && fake.stops == 1)
  await settle()
  #expect(model.focusedArgument == "hours" && editing(hours))

  // Typing into the slot fills the draft; an arrow from the slot moves the selection, and the slots
  // going away hand the keys back to the input.
  let editor = try #require(hours.currentEditor() as? NSTextView)
  editor.insertText("4", replacementRange: editor.selectedRange())
  #expect(model.argumentValues == ["hours": "4"] && model.input == "caff")
  let row = try #require(model.selection)
  #expect(panel.route(voiceKey(125, "")))
  await settle()
  #expect(model.selection != row && model.declaredArguments.isEmpty && model.focusedArgument == nil)
  #expect(editing(input) && model.argumentValues.isEmpty)
  #expect(!panel.route(voiceKey(48, "\t")))  // No slots: Tab is AppKit's again.

  // Return from a slot enters the command with the filled values; the slots stay, with them.
  #expect(panel.route(voiceKey(126, "")))
  await settle()
  #expect(model.selection == row && model.moveFocus(1))
  await settle()
  let again = try #require(slot("hours")?.currentEditor() as? NSTextView)
  again.insertText("2", replacementRange: again.selectedRange())
  #expect(panel.route(voiceKey(36, "\r")))
  await settle()
  #expect(model.command?.id == "extension:caffeinate" && model.argumentValues == ["hours": "2"])
  #expect(slot("hours")?.stringValue == "2" && model.focusedArgument == "hours")

  // Escape leaves the command and the input has the keys.
  #expect(panel.route(voiceKey(53, "\u{1b}")))
  await settle()
  #expect(model.command == nil && model.focusedArgument == nil && editing(input))
  controller.hide()
  await model.finish()
}

@MainActor @Test func aClickOnTheSelectedCommandRowWithADraftEntersIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(root, name: "caffeinate", fields: ["arguments": [["name": "hours"]]])
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  model.input = "caff"
  await model.settled()
  let row = try #require(model.selection)
  let other = try #require(model.results.first { $0.id != row }).id
  // Without a draft a click selects; with one, a click on that row is Return, on another it selects.
  #expect(!model.click(row) && model.selection == row)
  model.setArgument("hours", to: "4")
  model.moveFocus(1)
  #expect(!model.click(other) && model.selection == other && model.focusedArgument == nil)
  #expect(!model.click(row))
  model.setArgument("hours", to: "4")
  #expect(model.click(row) && model.selection == row)
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.command?.arguments == ["hours": "4"])
  // Dismissing drops the focus with the slots.
  model.moveFocus(1)
  #expect(model.focusedArgument == "hours")
  model.dismiss()
  #expect(model.focusedArgument == nil)
  await model.finish()
}
