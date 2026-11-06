import AppKit
import WicketCore

/// Runs item actions: the one place where activating a result touches the system.
@MainActor
struct ActionRunner {
    let commands: CommandsSource

    func run(_ action: Item.Action) {
        if let url = action.revealedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        switch action {
        case .open(let url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if let error { Perf.logger.error("open failed: \(error)") }
            }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .command(let id):
            commands.run(id)
        }
    }
}
