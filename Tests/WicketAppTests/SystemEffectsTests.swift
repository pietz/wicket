import AppKit
import Testing
import WicketCore

@testable import WicketApp

// The effects that need no other app: each uses a private pasteboard, so the user's clipboard is
// never touched, and no open reaches macOS.

@MainActor
private final class Effects {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("wicket-test-\(UUID())"))
    let messages = Messages()
    private(set) var shown: [Message] = []
    let effects: SystemEffects

    init() {
        effects = SystemEffects(messages: messages, pasteboard: pasteboard)
        messages.present = { [unowned self] in shown.append($0) }
    }

    var clipboard: String? { pasteboard.string(forType: .string) }

    /// Lets the effects' tasks run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    isolated deinit { pasteboard.releaseGlobally() }
}

/// Copying used to close the palette without a word.
@MainActor @Test func aCopySaysCopied() async {
    let e = Effects()
    e.effects.copy("42")
    #expect(e.clipboard == "42")
    // Not before the palette closes: the dispatcher hides it in this same turn.
    #expect(e.shown.isEmpty)
    await e.settle()
    #expect(e.shown == [Message("Copied", kind: .copied)])
}

/// A paste that can only copy says so once, never "Copied" as well.
@MainActor @Test func aPasteThatOnlyCopiesShowsOneMessage() async {
    let e = Effects()
    e.effects.paste("😸", into: nil)
    #expect(e.clipboard == "😸")
    await e.settle()
    #expect(e.shown == [Message(PasteFallback.noTarget.message, kind: .copied)])
}

/// One pending paste: a newer paste or a copy replaces the older before it does anything.
@MainActor @Test func aNewerPasteOrCopyCancelsThePendingPaste() async {
    let e = Effects()
    e.effects.paste("old", into: nil)
    e.effects.paste("new", into: nil)
    await e.settle()
    #expect(e.clipboard == "new")
    #expect(e.shown == [Message(PasteFallback.noTarget.message, kind: .copied)])

    e.effects.paste("pasted", into: nil)
    e.effects.copy("copied")
    await e.settle()
    #expect(e.clipboard == "copied")
    #expect(e.shown.dropFirst() == [Message("Copied", kind: .copied)])
}

/// An open that failed used to be logged only.
@MainActor @Test func openingAMissingFileSaysWhy() async {
    let e = Effects()
    e.effects.open(URL(filePath: "/tmp/wicket-missing-\(UUID())"))
    await e.settle()
    #expect(e.shown == [Message("Couldn't open it: it was moved or deleted", kind: .failed)])
}

@Test func aMissingFileOrDiskIsToldApart() {
    let mounted: Set = ["/Volumes/Backup"]
    let exists = { (path: String) in mounted.contains(path) }
    #expect(
        SystemEffects.missing(URL(filePath: "/Volumes/Archive/a.pdf"), exists: exists)
            == "its disk isn't connected")
    #expect(
        SystemEffects.missing(URL(filePath: "/Volumes/Backup/a.pdf"), exists: exists)
            == "it was moved or deleted")
    #expect(
        SystemEffects.missing(URL(filePath: "/Users/me/a.pdf"), exists: exists) == "it was moved or deleted")
    #expect(SystemEffects.missing(URL(filePath: "/Users/me/a.pdf"), exists: { _ in true }) == nil)
    #expect(SystemEffects.missing(URL(string: "https://example.com")!, exists: { _ in false }) == nil)
}

@Test func anOpenErrorBecomesAShortReason() {
    let noApp = NSError(domain: NSOSStatusErrorDomain, code: Int(kLSApplicationNotFoundErr))
    let wrapped = NSError(
        domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: noApp])
    #expect(SystemEffects.reason(for: wrapped) == "no app opens it")
    #expect(
        SystemEffects.reason(for: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
            == "it was moved or deleted")
    // The user cancelled (a Gatekeeper prompt): nothing to say.
    #expect(SystemEffects.reason(for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) == nil)
    #expect(SystemEffects.reason(for: NSError(domain: "other", code: 1)) == "macOS refused")
}
