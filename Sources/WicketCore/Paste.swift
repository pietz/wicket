/// Paste-back, decided before anything touches the system: whether a `paste` action can type into
/// the app the user came from, and what to say when it can't. The app carries the plan out
/// (`SystemEffects`): the text always goes on the clipboard first, so every fallback is a copy.
public enum PastePlan: Sendable, Hashable {
    /// Bring `app` to the front and press ⌘V in it.
    case paste(into: RunningApp)
    /// Leave the text on the clipboard and say why it wasn't pasted.
    case copyOnly(PasteFallback)

    /// The plan for pasting into `target`, the app frontmost at summon. Accessibility is asked for
    /// only when it is the one thing missing, so a paste that couldn't have worked anyway (no app,
    /// or it quit) never prompts; and only once per session (`hasPrompted`), so it never nags.
    public static func decide(
        target: RunningApp?, isRunning: Bool, isTrusted: Bool, hasPrompted: Bool
    ) -> PastePlan {
        guard let target else { return .copyOnly(.noTarget) }
        guard isRunning else { return .copyOnly(.targetQuit(target)) }
        guard isTrusted else { return .copyOnly(.notTrusted(prompt: !hasPrompted)) }
        return .paste(into: target)
    }
}

/// Why a paste only copied.
public enum PasteFallback: Sendable, Hashable {
    /// Wicket itself was frontmost at summon (its settings window), so there is nowhere to paste.
    case noTarget
    /// The app quit while the palette was open.
    case targetQuit(RunningApp)
    /// Synthesising ⌘V needs Accessibility; `prompt` says whether to ask for it now.
    case notTrusted(prompt: Bool)
    /// The app didn't come to the front in time, so ⌘V could have landed somewhere else.
    case notFrontmost(RunningApp)

    /// The HUD's line.
    public var message: String {
        switch self {
        case .noTarget: "Copied: no app to paste into"
        case .targetQuit(let app): "Copied: \(app.name ?? "the app") has quit"
        case .notTrusted: "Copied: allow Wicket in Accessibility to paste"
        case .notFrontmost(let app): "Copied: couldn't switch to \(app.name ?? "the app")"
        }
    }
}

/// Finds the key that types a character on the current keyboard layout, so a synthesised shortcut
/// means the same on every layout. ⌘V is not always the ANSI V key: on Dvorak that key types K, and
/// V sits where ANSI has the full stop. "Dvorak - QWERTY ⌘" switches to QWERTY while ⌘ is held,
/// which is why the app translates keys with ⌘ down.
public enum KeyLookup {
    /// Every virtual key code a layout can map.
    static let keyCodes: ClosedRange<UInt16> = 0...127

    /// The key that types `character` in the first layout that has one, trying `preferred` (the
    /// ANSI key) first so the common case needs one translation, else `preferred`. Each layout is a
    /// translation from key code to the text it types (nil if it types nothing); the app passes the
    /// current layout, then the current ASCII-capable one for layouts with no Latin letters.
    public static func keyCode(
        typing character: Character, preferring preferred: UInt16, in layouts: [(UInt16) -> String?]
    ) -> UInt16 {
        let wanted = String(character).lowercased()
        let candidates = [preferred] + keyCodes.filter { $0 != preferred }
        for translate in layouts {
            if let code = candidates.first(where: { translate($0)?.lowercased() == wanted }) {
                return code
            }
        }
        return preferred
    }
}
