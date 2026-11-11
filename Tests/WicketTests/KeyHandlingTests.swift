import Testing

@testable import WicketApp

@Test(arguments: [
  (53, PaletteKeyAction.dismiss), (36, .run), (76, .run), (125, .move(1)), (126, .move(-1)),
  (0, .passThrough), (51, .passThrough), (123, .passThrough), (124, .passThrough),
])
func plainKeys(code: Int, action: PaletteKeyAction) {
  #expect(
    PaletteKeyAction.decide(keyCode: code, characters: nil, modifiers: [], hasMarkedText: false)
      == action)
}

@Test func inputMethodsKeepEveryCompositionKey() {
  for code in [53, 36, 76, 125, 126, 0] {
    for modifiers: Shortcut.Modifiers in [[], .command, .control, .option] {
      #expect(
        PaletteKeyAction.decide(
          keyCode: code, characters: "n", modifiers: modifiers, hasMarkedText: true) == .passThrough
      )
    }
  }
}

@Test func editShortcutsAndCommandIsolation() {
  for (key, edit) in [
    ("x", PaletteKeyAction.Edit.cut), ("c", .copy), ("v", .paste), ("a", .selectAll), ("z", .undo),
  ] {
    #expect(
      PaletteKeyAction.decide(
        keyCode: 0, characters: key, modifiers: .command, hasMarkedText: false) == .edit(edit))
  }
  #expect(
    PaletteKeyAction.decide(
      keyCode: 6, characters: "Z", modifiers: [.command, .shift], hasMarkedText: false)
      == .edit(.redo))
  for key in ["q", "w", "h", "m", ",", "\r"] {
    #expect(
      PaletteKeyAction.decide(
        keyCode: 0, characters: key, modifiers: .command, hasMarkedText: false) == .consume)
  }
  #expect(
    PaletteKeyAction.decide(
      keyCode: 8, characters: "c", modifiers: [.command, .shift], hasMarkedText: false) == .consume)
}

@Test func navigationDoesNotTakeOverTextEditing() {
  #expect(
    PaletteKeyAction.decide(keyCode: 45, characters: "n", modifiers: .control, hasMarkedText: false)
      == .move(1))
  #expect(
    PaletteKeyAction.decide(keyCode: 35, characters: "p", modifiers: .control, hasMarkedText: false)
      == .move(-1))
  #expect(
    PaletteKeyAction.decide(keyCode: 0, characters: "a", modifiers: .control, hasMarkedText: false)
      == .passThrough)
  #expect(
    PaletteKeyAction.decide(keyCode: 0, characters: "å", modifiers: .option, hasMarkedText: false)
      == .passThrough)
  #expect(
    PaletteKeyAction.decide(keyCode: 36, characters: "\r", modifiers: .shift, hasMarkedText: false)
      == .passThrough)
}

@MainActor @Test func conflictingHotkeyEditKeepsTheWorkingRegistration() throws {
  final class Handle {}
  let original = Shortcut.default
  let replacement = try Shortcut("ctrl+option+shift+w")
  weak var oldHandle: Handle?
  var acceptsReplacement = false
  var attempts = 0
  let binding = PaletteHotKey { shortcut in
    attempts += 1
    if shortcut == replacement && !acceptsReplacement { return nil }
    let handle = Handle()
    if shortcut == original { oldHandle = handle }
    return handle
  }
  #expect(binding.apply(original) == nil)
  #expect(oldHandle != nil)
  #expect(binding.apply(original) == nil)
  #expect(attempts == 1)
  #expect(binding.apply(replacement) != nil)
  #expect(binding.inEffect == original)
  #expect(oldHandle != nil)
  acceptsReplacement = true
  #expect(binding.apply(replacement) == nil)
  #expect(binding.inEffect == replacement)
  #expect(oldHandle == nil)
}

@MainActor @Test func initialHotkeyConflictLeavesTheMenuAvailable() {
  let binding = PaletteHotKey { _ in nil }
  #expect(binding.apply(.default)?.contains("Menu bar") == true)
  #expect(binding.inEffect == nil)
}

@MainActor @Test func launcherPanelCanTakeKeyboardFocus() {
  #expect(PalettePanel().canBecomeKey)
}
