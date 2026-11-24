import Foundation

@MainActor func openLink(_ url: URL, bundleID: String?) async throws {
  let application: String
  switch bundleID {
  case "test.browser": application = "\n/Probe.app"
  case nil: application = ""
  default: throw MissingBrowser(errorDescription: "Missing app for \(bundleID ?? "")")
  }
  try (url.absoluteString + application).write(
    to: URL(fileURLWithPath: "opened"), atomically: true, encoding: .utf8)
}

private struct MissingBrowser: LocalizedError {
  let errorDescription: String?
}
