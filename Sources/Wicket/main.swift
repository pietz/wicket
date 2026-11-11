import AppKit
import WicketApp

if Headless.requested {
  Task { @MainActor in exit(await Headless.run()) }
  RunLoop.main.run()
} else {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
