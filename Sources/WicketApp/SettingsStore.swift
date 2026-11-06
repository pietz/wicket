import AppKit
import WicketCore
import WicketHost

/// settings.json as the app applied it, for the app and the settings window. The file is the single
/// source of truth: the window writes it through `update`, and the folder's FileWatcher calls
/// `reload`, so the window never changes the app's state any other way.
@MainActor
@Observable
final class SettingsStore {
    let url: URL
    /// The app's diagnostics: the panes read their problem lines here. `reload` reports settings.json
    /// (`.settings`), the runtime the hotkeys and aliases (`.binding`) and keyword conflicts.
    let diagnostics: Diagnostics
    private(set) var settings = Settings()
    /// The registered commands, for the Shortcuts pane. Set by the runtime.
    var commands: [RegisteredCommand] = []
    /// Stops the global hotkeys (the palette's and the commands') while the settings window records
    /// a new one, so pressing a current combination reaches the recorder instead of running what it
    /// is bound to. Set by the app delegate.
    @ObservationIgnored var pauseHotKey: (Bool) -> Void = { _ in }

    init(directory: URL, diagnostics: Diagnostics = Diagnostics()) {
        url = directory.appending(path: "settings.json")
        self.diagnostics = diagnostics
    }

    /// Why settings.json could not be loaded, while the last good settings are in use.
    var loadError: String? {
        diagnostics.entries(for: .settings).first { $0.severity == .error }?.text
    }

    /// True when `settings.hotkey` could not be registered because another app owns it.
    var hotKeyFailed: Bool {
        diagnostics.text(for: .bindings, kind: .binding) != nil
    }

    /// Loads settings.json: defaults if it is missing; if it is invalid (often an agent or editor
    /// halfway through a write), the last good settings stay, so nothing resets and restarts.
    func reload() {
        do {
            settings = try Settings.load(from: url)
            diagnostics.set(.settings, of: .settings, .warning, settings.ignored)
            for reason in settings.ignored {
                Perf.logger.error("settings.json: \(reason, privacy: .public)")
            }
        } catch {
            let reason = error.localizedDescription
            Perf.logger.error("\(reason, privacy: .public); keeping the last good settings")
            diagnostics.set(.settings, of: .settings, .error, [reason])
        }
    }

    /// Writes a change to settings.json, keeping fields this build doesn't know.
    func update(_ change: (inout Settings) -> Void) throws {
        try Settings.update(at: url, change)
    }

    /// Opens settings.json in the user's editor (or reveals it if nothing opens JSON), creating it
    /// with the current values first if it does not exist.
    func openFile() throws {
        if !FileManager.default.fileExists(atPath: url.path) { try update { _ in } }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
