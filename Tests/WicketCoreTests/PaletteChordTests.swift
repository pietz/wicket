import Testing

@testable import WicketCore

@Test func chordsMatchTheKeyboardModel() {
    #expect(PaletteChord(keyCode: 0x28, characters: "k", modifiers: .command) == .toggleActions)
    #expect(PaletteChord(keyCode: 0x24, characters: "\r", modifiers: .command) == .runSecondary)
    #expect(PaletteChord(keyCode: 0x4C, characters: "\u{3}", modifiers: .command) == .runSecondary)
    #expect(PaletteChord(keyCode: 0x2B, characters: ",", modifiers: .command) == .openSettings)
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
