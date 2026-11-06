/// The palette's keyboard chords. The panel matches them before the focused text field sees the key,
/// because the field editor binds some of them itself (⌃N and ⌃P move the caret) and SwiftUI's
/// `onKeyPress` never sees those.
public enum PaletteChord: Equatable, Sendable {
    /// ⌘K: open or close the action panel.
    case toggleActions
    /// ⌘↩: run the selected item's second action.
    case runSecondary
    /// ⌘1 to ⌘9: run the primary action of that row, zero-based.
    case runRow(Int)
    /// ⌘,: open the settings window.
    case openSettings
    /// ⌃N and ⌃P: move the selection, like ↓ and ↑.
    case move(Int)

    /// The physical number row, by key code, so ⌘1 works on layouts that need Shift for digits.
    private static let numberRow = (1...9).map { Shortcut.keyCodes[String($0)]! }
    private static let returnKey = Shortcut.keyCodes["return"]!
    private static let keypadEnter = 0x4C

    /// `characters` is the key's text ignoring modifiers, so letters follow the keyboard layout.
    public init?(keyCode: Int, characters: String?, modifiers: Shortcut.Modifiers) {
        let character = characters?.lowercased()
        switch modifiers {
        case .command:
            if let row = Self.numberRow.firstIndex(of: keyCode) {
                self = .runRow(row)
            } else if keyCode == Self.returnKey || keyCode == Self.keypadEnter {
                self = .runSecondary
            } else if character == "k" {
                self = .toggleActions
            } else if character == "," {
                self = .openSettings
            } else {
                return nil
            }
        case .control:
            switch character {
            case "n": self = .move(1)
            case "p": self = .move(-1)
            default: return nil
            }
        default:
            return nil
        }
    }
}
