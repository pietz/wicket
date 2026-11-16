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
