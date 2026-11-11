import Foundation
import Testing

@testable import WicketApp

@MainActor @Test func unrelatedFolderWritesDoNotReloadConfiguration() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigurationStore(url: root.appending(path: "config.json"))
  var count = 0
  store.onChange = { _, _ in count += 1 }
  store.start()
  #expect(await eventually { count > 0 })
  try await Task.sleep(for: .milliseconds(300))
  let baseline = count
  try Data("{}".utf8).write(to: root.appending(path: "usage.json"))
  try await Task.sleep(for: .milliseconds(400))
  #expect(count == baseline)
}
