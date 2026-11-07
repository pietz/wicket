import Foundation
import Testing
import WicketCore

@testable import WicketApp

/// The palette's chrome around the frames: the footer's message and hints, and what VoiceOver reads.
@MainActor
struct PaletteShellTests {
    let source = StaticSource("test", items: [])
    let model: PaletteModel

    init() {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/\(UUID().uuidString)/usage.json")
        model = PaletteModel(sources: [source], usageURL: url)
    }

    /// The footer shows a message with its kind's symbol, as the HUD does, not always a checkmark.
    @Test func footerMessageKeepsItsKind() {
        model.showToast(Message("Copied, Mail can't take a paste", kind: .copied))
        #expect(model.toast?.kind == .copied)
        #expect(model.toast?.kind.symbol == "doc.on.clipboard")
        #expect(Message.Kind.done.symbol == "checkmark.circle.fill")
        model.showToast(nil)
        #expect(model.toast == nil)
    }

    /// With nothing to run the footer says what Escape does: clear the text, else go back.
    @Test func emptyListFooterHintsAtEscape() {
        #expect(model.escapeHint == nil)
        model.query = "zzz"
        #expect(model.target == nil)
        #expect(model.escapeHint == "Clear")
        model.query = ""
        model.session.push(Detail(title: "Page", markdown: "Text"))
        #expect(model.escapeHint == "Back")
    }

    @Test func resultRowsReadTheirTitleSubtitleAndAccessory() {
        var row = item("Safari")
        #expect(ResultRow.accessibilityLabel(for: row) == "Safari")
        row.subtitle = "/Applications"
        row.accessory = "App"
        #expect(ResultRow.accessibilityLabel(for: row) == "Safari, /Applications, App")
    }
}
