import AppKit

extension BrowserOpener {
  static var system: Self {
    let workspace = NSWorkspace.shared
    return Self(
      application: workspace.urlForApplication(withBundleIdentifier:),
      open: { url, application in
        let configuration = NSWorkspace.OpenConfiguration()
        if let application {
          _ = try await workspace.open([url], withApplicationAt: application, configuration: configuration)
        } else {
          _ = try await workspace.open(url, configuration: configuration)
        }
      })
  }
}
