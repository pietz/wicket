import AppKit
import WicketCore

/// Runs item actions: the one place where activating a result touches the system.
@MainActor
struct ActionRunner {
    let commands: CommandsSource

    func run(_ action: Item.Action) {
        switch action {
        case .open(let url, _):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if let error { Perf.logger.error("open failed: \(error)") }
            }
        // Pasting into the previous app needs the Accessibility permission flow; until that lands,
        // paste copies, which is what the spec prescribes without the permission.
        case .copy(let text, _), .paste(let text, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .reveal(let url, _):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .command(let id):
            commands.run(id)
        case .detail:
            // The palette pushes details itself (`PaletteController.run`); they never get here.
            break
        case .run:
            // Extension commands: the palette integration (refactor step 6) will run them in a frame.
            Perf.logger.notice("extension run actions are not wired into the palette yet")
        }
    }
}
