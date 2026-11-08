import Testing

@testable import WicketCore

@Test func chordsMatchTheKeyboardModel() {
    #expect(PaletteChord(keyCode: 0x28, characters: "k", modifiers: .command) == .toggleActions)
    #expect(PaletteChord(keyCode: 0x24, characters: "\r", modifiers: .command) == .runSecondary)
    #expect(PaletteChord(keyCode: 0x4C, characters: "\u{3}", modifiers: .command) == .runSecondary)
    #expect(PaletteChord(keyCode: 0x2B, characters: ",", modifiers: .command) == .openSettings)
    #expect(PaletteChord(keyCode: 0x25, characters: "l", modifiers: .command) == .listen)
    #expect(PaletteChord(keyCode: 0x2D, characters: "n", modifiers: .control) == .move(1))
    #expect(PaletteChord(keyCode: 0x23, characters: "p", modifiers: .control) == .move(-1))
}

@Test func numberRowMatchesByKeyCode() {
    // AZERTY: the 1 key types "&" without Shift.
    #expect(PaletteChord(keyCode: 0x12, characters: "&", modifiers: .command) == .runRow(0))
    #expect(PaletteChord(keyCode: 0x19, characters: "9", modifiers: .command) == .runRow(8))
    #expect(PaletteChord(keyCode: 0x1D, characters: "0", modifiers: .command) == nil)
}

@Test func otherKeysAndModifiersAreLeftToTheField() {
    #expect(PaletteChord(keyCode: 0x28, characters: "k", modifiers: []) == nil)
    #expect(PaletteChord(keyCode: 0x28, characters: "k", modifiers: [.command, .shift]) == nil)
    #expect(PaletteChord(keyCode: 0x24, characters: "\r", modifiers: []) == nil)
    #expect(PaletteChord(keyCode: 0x2D, characters: "n", modifiers: .command) == nil)
    #expect(PaletteChord(keyCode: 0x00, characters: "a", modifiers: .command) == nil)
}

@Test func editingShortcutsGoToTheField() {
    #expect(EditCommand(characters: "c", modifiers: .command) == .copy)
    #expect(EditCommand(characters: "x", modifiers: .command) == .cut)
    #expect(EditCommand(characters: "v", modifiers: .command) == .paste)
    #expect(EditCommand(characters: "a", modifiers: .command) == .selectAll)
    #expect(EditCommand(characters: "z", modifiers: .command) == .undo)
    // Shift makes the character uppercase.
    #expect(EditCommand(characters: "Z", modifiers: [.command, .shift]) == .redo)
    #expect(EditCommand(characters: "C", modifiers: [.command, .shift]) == nil)
    #expect(EditCommand(characters: "c", modifiers: .control) == nil)
}

/// The panel claims chords before the main menu and swallows the rest of the menu's keys, so the
/// palette's ⌘ keys must stay distinct: ⌘, is a chord (the menu's Settings… never runs from the
/// palette), and the menu's window and app keys are neither, which leaves them to be swallowed.
@Test func paletteKeysAreNotTheMenusWindowKeys() {
    let menuOnly: [(Int, String)] = [(0x0C, "q"), (0x0D, "w"), (0x04, "h"), (0x2E, "m")]
    for (keyCode, character) in menuOnly {
        #expect(PaletteChord(keyCode: keyCode, characters: character, modifiers: .command) == nil)
        #expect(EditCommand(characters: character, modifiers: .command) == nil)
    }
    for (row, keyCode) in [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19].enumerated() {
        #expect(PaletteChord(keyCode: keyCode, characters: "\(row + 1)", modifiers: .command) == .runRow(row))
    }
    #expect(PaletteChord(keyCode: 0x2B, characters: ",", modifiers: .command) == .openSettings)
}
