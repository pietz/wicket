import AppKit
import WicketCore

/// Captures the files the user had selected in Finder when they summoned Wicket (`SummonContext`),
/// for Run Agent's folder. It starts once the palette is on screen, so it costs hotkey-to-visible
/// nothing, and runs off the main actor.
///
/// It never asks for a permission: Finder's selection needs Automation of Finder, and the Apple event
/// is sent so that it fails rather than prompts unless that was granted (Settings ▸ AI asks). The
/// event is bounded by `timeout`, and the session waits for the capture at most 300 ms anyway.
/// Nothing captured is logged, only timings.
enum ContextCapture {
    /// How long the Apple event may take before it is given up.
    static let timeout: Float = 0.15

    /// Starts capturing from `app`, the app frontmost at summon; nil unless it is Finder.
    static func start(from app: RunningApp?) -> Task<SummonContext?, Never>? {
        guard app?.bundleID == finderID else { return nil }
        return Task.detached {
            let start = ContinuousClock.now
            let context = SummonContext(files: finderSelection())
            Perf.log(
                "context captured in \(Perf.ms(since: start)): \(context == nil ? "nothing" : "something")")
            return context
        }
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
