import AppKit
import WicketCore

/// settings.json as the app applied it, for the app and the settings window. The file is the single
/// source of truth: the window writes it through `update`, and the folder's FileWatcher calls
/// `reload`, so the window never changes the app's state any other way.
@MainActor
@Observable
final class SettingsStore {
    let url: URL
    private(set) var settings = Settings()
    /// Why settings.json could not be loaded, while defaults are in use.
    private(set) var loadError: String?
    /// True when `settings.hotkey` could not be registered because another app owns it.
    var hotKeyFailed = false
    /// The registered commands, for the Shortcuts pane. Set by the app delegate.
    var commands: [RegisteredCommand] = []
    /// Why a command's hotkey or alias from settings.json isn't in effect (taken by the palette or
    /// another command, held by another app). Set by the app delegate.
    var bindingProblems: [CommandID: String] = [:]
    /// Stops the global hotkeys (the palette's and the commands') while the settings window records
    /// a new one, so pressing a current combination reaches the recorder instead of running what it
    /// is bound to. Set by the app delegate.
    @ObservationIgnored var pauseHotKey: (Bool) -> Void = { _ in }

    init(directory: URL) {
        url = directory.appending(path: "settings.json")
    }

    /// Loads settings.json: defaults if it is missing; if it is invalid (often an agent or editor
    /// halfway through a write), the last good settings stay, so nothing resets and restarts.
    func reload() {
        do {
            settings = try Settings.load(from: url)
            loadError = nil
            for reason in settings.ignored {
                Perf.logger.error("settings.json: \(reason, privacy: .public)")
            }
        } catch {
            let reason = error.localizedDescription
            Perf.logger.error("\(reason, privacy: .public); keeping the last good settings")
            loadError = reason
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
