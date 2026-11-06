import WicketCore

/// The global hotkeys bound to commands (settings.json `commands`), one Carbon registration each
/// (`HotKey`), kept in step with what `CommandHotkeys.resolve` allows.
///
/// Applying settings is two steps around the palette's own hotkey: `update` resolves the bindings
/// and drops registrations no longer wanted (so a combination just given to the palette is free),
/// then `apply` registers the rest (after the palette let go of its old one). A registration that
/// fails (another app holds the combination) is tried again on the next `apply`.
@MainActor
final class BoundHotKeys {
    /// Called with the command whose hotkey was pressed.
    var onPress: (CommandID) -> Void = { _ in }
    /// True while the settings window records a hotkey: nothing is registered, so pressing a bound
    /// combination reaches the recorder.
    var paused = false {
        didSet {
            dropUnwanted()
            apply()
        }
    }
    private var wanted: [Shortcut: CommandID] = [:]
    private var rejected: [CommandHotkeys.Rejection] = []
    private var registered: [Shortcut: (command: CommandID, hotKey: HotKey)] = [:]
    /// Commands whose hotkey another app holds.
    private var failed: [CommandID: Shortcut] = [:]

    /// Resolves the bindings against the palette's hotkey and the registry, logs the rejected ones
    /// and alias conflicts, and unregisters what is no longer wanted.
    func update(_ settings: Settings, registry: CommandRegistry) {
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
        dropUnwanted()
    }

    /// Registers every wanted hotkey that isn't yet.
    func apply() {
        failed = [:]
        guard !paused else { return }
        for (shortcut, id) in wanted where registered[shortcut] == nil {
            let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue) {
                [weak self] _ in
                self?.onPress(id)
            }
            if let hotKey {
                registered[shortcut] = (id, hotKey)
            } else {
                failed[id] = shortcut
                Perf.logger.error(
                    "could not register hotkey \(shortcut, privacy: .public) for \(id, privacy: .public); another app owns it"
                )
            }
        }
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

    private func dropUnwanted() {
        for (shortcut, entry) in registered where paused || wanted[shortcut] != entry.command {
            registered[shortcut] = nil  // Unregisters it.
        }
    }
}
