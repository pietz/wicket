import WicketApp

// App entry point: starts the AppKit lifecycle in WicketApp, a library its tests can import.
MainActor.assumeIsolated { AppDelegate.run() }
