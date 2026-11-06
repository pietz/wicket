import AppKit
import WicketCore
import WicketHost

/// The action dispatcher's side effects on this Mac: the one place where activating a result
/// touches the system.
@MainActor
final class SystemEffects: ActionEffects {
    private let extensions: Extensions
    private let showSettings: () -> Void

    init(extensions: Extensions, showSettings: @escaping () -> Void) {
        self.extensions = extensions
        self.showSettings = showSettings
    }

    /// Doesn't wait for the app to launch: the palette closes at once.
    func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { Perf.logger.error("open failed: \(error)") }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Typing into `app` needs the Accessibility permission flow; until that lands, paste copies,
    /// which is what docs/extensions.md prescribes without the permission.
    func paste(_ text: String, into app: RunningApp?) {
        copy(text)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openSettings() {
        showSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func run(_ invocation: Invocation) async throws -> RunResult {
        try await extensions.run(invocation, kind: .action)
    }
}
