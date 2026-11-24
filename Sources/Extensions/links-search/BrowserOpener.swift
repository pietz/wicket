import AppKit

@MainActor func openLink(_ url: URL, bundleID: String?) async throws {
  let workspace = NSWorkspace.shared
  let configuration = NSWorkspace.OpenConfiguration()
  if let bundleID {
    guard let application = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
      throw LinkFailure(errorDescription: "Install the app or update its bundle ID (\(bundleID)).")
    }
    _ = try await workspace.open([url], withApplicationAt: application, configuration: configuration)
  } else {
    _ = try await workspace.open(url, configuration: configuration)
  }
}

private struct LinkFailure: LocalizedError {
  let errorDescription: String?
}
