import AppKit

/// The application's delegate: starts the runtime (`AppRuntime`, which composes the app and applies
/// settings.json) and forwards the few app-level events.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AppRuntime?

    /// Starts the app: an accessory (no Dock icon) running this delegate. `main.swift` calls it.
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let runtime = AppRuntime.live()
        self.runtime = runtime
        runtime.start()
        if !CommandLine.arguments.contains("--background") { runtime.showPalette() }
    }

    /// Quitting waits for the runtime to stop what it started (agents, extension processes), at
    /// most about 2 s, so nothing is left running or cut off mid-write.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        Task {
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The main menu's Settings… item, sent up the responder chain.
    @objc func showSettings(_ sender: Any?) {
        runtime?.showSettings()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime?.showPalette()
        return false
    }
}
