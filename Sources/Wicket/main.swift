import WicketApp

// Everything lives in the WicketApp library, so tests can `@testable import` it.
MainActor.assumeIsolated { AppDelegate.run() }
