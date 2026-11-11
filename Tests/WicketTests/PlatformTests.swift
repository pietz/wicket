import AppKit
import Testing

@testable import WicketApp

@Test func scanningHandlesVendorFoldersEmbeddedAppsAndDuplicateScopes() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  for path in [
    "Editor.app/Contents/Applications/Helper.app", "Vendor/Tool.app", ".Hidden.app",
    "Archive.bundle/Ignore.app",
  ] {
    try FileManager.default.createDirectory(
      at: root.appending(path: path), withIntermediateDirectories: true)
  }
  let apps = AppsProvider.scan([root.path, root.appending(path: "Editor.app").path])
  #expect(Set(apps.map(\.name)) == ["Editor", "Helper", "Tool"])
  #expect(apps.count == 3)
}

@MainActor @Test func liveConfigReloadSurvivesInvalidAndAtomicEdits() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "config.json")
  let watcher = ConfigurationStore(url: url)
  var current: Configuration?
  var problem: String?
  watcher.onChange = { config, error in
    if let config { current = config }
    problem = error
  }
  watcher.start()
  #expect(await eventually { current != nil })
  try Data("{".utf8).write(to: url, options: .atomic)
  #expect(await eventually { problem != nil })
  #expect(current == Configuration())
  var edited = Configuration()
  edited.backgroundTransparency = 0.7
  try edited.save(at: url)
  #expect(await eventually { current == edited && problem == nil })
}
