import Foundation
import WicketCore

/// Registers a system-wide hotkey, calling the handler on each press; nil if the combination is
/// taken (by another app, or already by this one, as Carbon refuses). Releasing the returned object
/// unregisters it. The app's is `HotKey` (Carbon); tests pass a fake, so no real hotkey is taken.
typealias RegisterHotKey = @MainActor (Shortcut, @escaping HotKey.Handler) -> AnyObject?

/// Every global hotkey Wicket holds: the palette's own (settings.json `hotkey`) and those bound to
/// commands (`commands`), kept in step with one settings snapshot and the registry by `apply`.
///
/// The order of `apply` lets one change move a combination between them: commands that no longer
/// want a hotkey let go of it first, so the palette can take it, and the rest register after the
/// palette let go of its old one. A registration that fails (another app holds the combination) is
/// tried again on the next `apply`; meanwhile the palette keeps the hotkey it had, so a conflicting
/// edit never leaves Wicket unsummonable.
@MainActor
final class HotKeys {
    /// Called with the press's event time when the palette's hotkey is pressed.
    var onPalette: (TimeInterval) -> Void = { _ in }
    /// Called with the command whose hotkey was pressed.
    var onCommand: (CommandID) -> Void = { _ in }
    /// True while the settings window records a hotkey: nothing is registered, so pressing a bound
    /// combination reaches the recorder. Takes effect on the next `apply`.
    var paused = false
    /// Why the palette's hotkey from settings isn't in effect (another app holds it), naming the one
    /// that still opens Wicket, if any; nil when it is.
    private(set) var paletteProblem: String?

    private let register: RegisterHotKey
    private var palette: AnyObject?
    /// The combination `palette` holds, or last held: kept while paused or after a failure, so a
    /// shortcut another app holds falls back to it.
    private var paletteShortcut: Shortcut?
    private var wanted: [Shortcut: CommandID] = [:]
    private var rejected: [CommandHotkeys.Rejection] = []
    private var registered: [Shortcut: (command: CommandID, registration: AnyObject)] = [:]
    /// Commands whose hotkey another app holds.
    private var failed: [CommandID: Shortcut] = [:]

    init(register: @escaping RegisterHotKey) {
        self.register = register
    }

    /// Resolves the bindings against the palette's hotkey and the registry (logging the rejected ones
    /// and alias conflicts), then registers what `settings` asks for, in the order above.
    func apply(_ settings: Settings, registry: CommandRegistry) {
        (wanted, rejected) = CommandHotkeys.resolve(
            settings.commands, palette: settings.hotkey, isRegistered: { registry.command($0) != nil })
        for rejection in rejected {
            Perf.logger.error("settings.json: \(rejection, privacy: .public)")
        }
        for conflict in registry.aliasConflicts {
            Perf.logger.error(
                "settings.json: commands.\(conflict.loser, privacy: .public).alias is already \(conflict.winner, privacy: .public)'s; ignoring it"
            )
        }
        for (shortcut, entry) in registered where paused || wanted[shortcut] != entry.command {
            registered[shortcut] = nil  // Unregisters it.
        }
        applyPalette(settings.hotkey)
        registerCommands()
    }

    /// Why each command's hotkey or alias isn't in effect, for the Shortcuts pane.
    func problems(_ registry: CommandRegistry) -> [CommandID: String] {
        let title = { (id: CommandID) in registry.command(id)?.title ?? id.description }
        var problems: [CommandID: [String]] = [:]
        for conflict in registry.aliasConflicts {
            problems[conflict.loser, default: []].append("The alias is already \(title(conflict.winner))'s.")
        }
        for rejection in rejected {
            let problem =
                switch rejection.reason {
                case .palette: "\(rejection.hotkey.symbols) opens Wicket."
                case .taken(let other): "\(rejection.hotkey.symbols) is already \(title(other))'s."
                }
            problems[rejection.command, default: []].append(problem)
        }
        for (id, hotkey) in failed {
            problems[id, default: []].append("\(hotkey.symbols) is in use by another app.")
        }
        return problems.mapValues { $0.joined(separator: " ") }
    }

    private func applyPalette(_ shortcut: Shortcut) {
        if paused {
            palette = nil
            paletteProblem = nil
            return
        }
        guard palette == nil || shortcut != paletteShortcut else { return }
        palette = nil  // Unregister first: Carbon refuses a combination this app already holds.
        let onPress: HotKey.Handler = { [weak self] eventTime in self?.onPalette(eventTime) }
        if let registration = register(shortcut, onPress) {
            (palette, paletteShortcut, paletteProblem) = (registration, shortcut, nil)
            Perf.log("hotkey: \(shortcut)")
            return
        }
        Perf.logger.error("could not register hotkey \(shortcut, privacy: .public); another app owns it")
        let problem = "\(shortcut.symbols) is in use by another app."
        paletteProblem = problem
        guard let previous = paletteShortcut, previous != shortcut else { return }
        palette = register(previous, onPress)
        if palette != nil { paletteProblem = problem + " \(previous.symbols) still opens Wicket." }
    }

    /// Registers every wanted command hotkey that isn't yet.
    private func registerCommands() {
        failed = [:]
        guard !paused else { return }
        for (shortcut, id) in wanted where registered[shortcut] == nil {
            if let registration = register(shortcut, { [weak self] _ in self?.onCommand(id) }) {
                registered[shortcut] = (id, registration)
            } else {
                failed[id] = shortcut
                Perf.logger.error(
                    "could not register hotkey \(shortcut, privacy: .public) for \(id, privacy: .public); another app owns it"
                )
            }
        }
    }
}
