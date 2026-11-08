import Foundation
import WicketCore

/// Registers a system-wide hotkey, calling the handler on each press; nil if the combination is
/// taken (by another app, or already by this one, as Carbon refuses). Releasing the returned object
/// unregisters it. The app's is `HotKey` (Carbon); tests pass a fake, so no real hotkey is taken.
typealias RegisterHotKey = @MainActor (Shortcut, @escaping HotKey.Handler) -> AnyObject?

/// The hotkey that opens Wicket (settings.json `hotkey`), kept in step with each settings snapshot by
/// `apply`. A registration that fails (another app holds the combination) is tried again on the next
/// `apply`; meanwhile the palette keeps the hotkey it had, so a conflicting edit never leaves Wicket
/// unsummonable.
@MainActor
final class PaletteHotKey {
    /// Called with the press's event time.
    var onPress: (TimeInterval) -> Void = { _ in }
    /// True while the settings window records a hotkey: nothing is registered, so pressing the
    /// current combination reaches the recorder. Takes effect on the next `apply`.
    var paused = false
    /// Why settings' hotkey isn't in effect (another app holds it), naming the one that still opens
    /// Wicket, if any; nil when it is.
    private(set) var problem: String?
    /// The combination that opens Wicket right now: settings' hotkey, the previous one if another
    /// app holds it, or nil if none is registered.
    var inEffect: Shortcut? { registration == nil ? nil : shortcut }

    private let register: RegisterHotKey
    private var registration: AnyObject?
    /// The combination `registration` holds, or last held: kept while paused or after a failure, so a
    /// shortcut another app holds falls back to it.
    private var shortcut: Shortcut?

    init(register: @escaping RegisterHotKey) {
        self.register = register
    }

    func apply(_ shortcut: Shortcut) {
        if paused {
            registration = nil
            problem = nil
            return
        }
        guard registration == nil || shortcut != self.shortcut else { return }
        registration = nil  // Unregister first: Carbon refuses a combination this app already holds.
        let onPress: HotKey.Handler = { [weak self] eventTime in self?.onPress(eventTime) }
        if let registration = register(shortcut, onPress) {
            (self.registration, self.shortcut, problem) = (registration, shortcut, nil)
            Perf.log("hotkey: \(shortcut)")
            return
        }
        Perf.logger.error("could not register hotkey \(shortcut, privacy: .public); another app owns it")
        let problem = "\(shortcut.symbols) is in use by another app."
        self.problem = problem
        guard let previous = self.shortcut, previous != shortcut else { return }
        registration = register(previous, onPress)
        if registration != nil { self.problem = problem + " \(previous.symbols) still opens Wicket." }
    }
}
