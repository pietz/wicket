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

    /// With nothing to run in a pushed frame the footer says Escape goes back; the root has no hint.
    @Test func pushedFrameFooterHintsAtBack() {
        model.query = "zzz"
        #expect(model.target == nil)
        #expect(!model.canGoBack)
        model.query = ""
        model.session.push(Detail(title: "Page", markdown: "Text"), from: .host)
        #expect(model.canGoBack)
    }

    /// "name, folder, accessory", the accessory being the producer's or a file's derived date.
    @Test func resultRowsReadTheirTitleSubtitleAndAccessory() {
        #expect(ResultRow.accessibilityLabel(title: "Safari", subtitle: nil, accessory: nil) == "Safari")
        #expect(
            ResultRow.accessibilityLabel(title: "Report.pdf", subtitle: "~/Documents", accessory: "Oct 30")
                == "Report.pdf, ~/Documents, Oct 30")
    }
}
