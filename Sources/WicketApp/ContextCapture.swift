import AppKit
import ApplicationServices
import WicketCore

/// Captures what the user had selected in the app they summoned Wicket from (`SummonContext`): the
/// files selected in Finder, else the text selected in the app's focused element. It starts once the
/// palette is on screen, so it costs hotkey-to-visible nothing, and runs off the main actor.
///
/// It never asks for a permission: selected text needs Accessibility, read only if Wicket is already
/// trusted (Paste asks for it, or Settings ▸ AI); Finder's selection needs Automation of Finder, sent
/// only if already granted (Settings ▸ AI asks). Each call to the other app is bounded by
/// `timeout`, and the session waits for the whole capture at most 300 ms anyway. The clipboard is
/// never read: macOS alerts the user when an app does. Nothing captured is logged, only timings.
enum ContextCapture {
    /// How long one Accessibility or Apple event call may take before it is given up.
    static let timeout: Float = 0.15

    /// Starts capturing from `app`, the app frontmost at summon; nil when there is none.
    static func start(from app: RunningApp?) -> Task<SummonContext?, Never>? {
        guard let app else { return nil }
        return Task.detached {
            let start = ContinuousClock.now
            let context = capture(from: app)
            Perf.log(
                "context captured in \(Perf.ms(since: start)): \(context == nil ? "nothing" : "something")")
            return context
        }
    }

    private static func capture(from app: RunningApp) -> SummonContext? {
        let name = app.name ?? "the app"
        if app.bundleID == finderID {
            return SummonContext(app: name, bundleID: app.bundleID, files: finderSelection())
        }
        guard AXIsProcessTrusted() else { return nil }
        return SummonContext(app: name, bundleID: app.bundleID, text: selectedText(in: app.processID))
    }

    // MARK: Selected text

    /// The text selected in the focused element of the app with `pid`; nil if it has none, or the
    /// app doesn't answer within the timeout.
    private static func selectedText(in pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement  // checked by the type id above
        AXUIElementSetMessagingTimeout(element, timeout)
        return attribute(kAXSelectedTextAttribute, of: element) as? String
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: Finder

    static let finderID = "com.apple.finder"

    /// Whether Wicket may send Finder Apple events: granted, not asked yet, or refused. `ask` shows
    /// macOS's prompt if it wasn't asked yet, and blocks until the user answers, so never call it
    /// on the main actor.
    static func finderAccess(ask: Bool) -> FinderAccess {
        let finder = NSAppleEventDescriptor(bundleIdentifier: finderID)
        switch AEDeterminePermissionToAutomateTarget(finder.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .refused
        }
    }

    enum FinderAccess {
        case granted, notAsked, refused
    }

    /// Finder's selection (`get selection as alias list`), sent so that macOS never prompts for it:
    /// empty unless Automation of Finder was granted.
    private static func finderSelection() -> [URL] {
        let finder = NSAppleEventDescriptor(bundleIdentifier: finderID)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), targetDescriptor: finder,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        // The application's `selection` property.
        guard
            let selection = NSAppleEventDescriptor.record().coerce(
                toDescriptorType: DescType(typeObjectSpecifier))
        else { return [] }
        selection.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass)
        )
        selection.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        selection.setDescriptor(
            NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        selection.setDescriptor(
            NSAppleEventDescriptor(typeCode: fourCC("sele")), forKeyword: AEKeyword(keyAEKeyData))
        event.setParam(selection, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(
            NSAppleEventDescriptor(typeCode: fourCC("alst")), forKeyword: AEKeyword(keyAERequestedType))
        let doNotPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        guard
            let reply = try? event.sendEvent(
                options: [.waitForReply, .neverInteract, doNotPrompt], timeout: TimeInterval(timeout)),
            let list = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), list.numberOfItems > 0
        else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
