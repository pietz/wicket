import Foundation
import Testing

@testable import WicketApp

@Test func extensionImagesUseRealPathsAndFallBackToTheManifest() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = FileManager.default
  let folder = root.appending(path: "extension")
  let outside = root.appending(path: "extension-other")
  let data = root.appending(path: "data/owner")
  for directory in [folder, outside, data] {
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  let png = fixtureURL("image-icons/release.png")
  let bundled = folder.appending(path: "bundled.PNG")
  let cached = data.appending(path: "cached.png")
  let foreign = outside.appending(path: "foreign.png")
  for target in [bundled, cached, foreign] { try files.copyItem(at: png, to: target) }
  try files.createSymbolicLink(at: folder.appending(path: "escape.png"), withDestinationURL: foreign)
  try files.createSymbolicLink(at: folder.appending(path: "internal.png"), withDestinationURL: bundled)
  try files.createSymbolicLink(at: folder.appending(path: "cache.png"), withDestinationURL: cached)
  try files.createSymbolicLink(at: folder.appending(path: "wrong-type.svg"), withDestinationURL: bundled)
  try Data("broken".utf8).write(to: folder.appending(path: "broken.png"))
  let svg =
    #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 12"><rect width="24" height="12" fill="red"/></svg>"#
  try Data(svg.utf8).write(to: folder.appending(path: "wide.svg"))
  let scope = ExtensionIcons.Scope(folder: folder, data: data, manifest: "wide.svg")
  let icons = ExtensionIcons.shared

  for path in ["bundled.PNG", "internal.png", bundled.path, cached.path] {
    #expect(await icons.image(for: .init(paths: [path], scope: scope)) != nil)
  }
  for path in [
    foreign.path, "../extension-other/foreign.png", "escape.png", "cache.png", "wrong-type.svg",
    "broken.png", "missing.png", cached.absoluteString, "https://example.com/icon.png", "wide.svg.",
  ] {
    #expect(await icons.image(for: .init(paths: [path], scope: scope)) == nil)
    let choices = ExtensionIcons.choices(path, manifest: scope.manifest)
    let image = try #require(await icons.image(for: .init(paths: choices.paths, scope: scope)))
    #expect(image.width == 78 && image.height == 39)
  }

  try Data("no longer an image".utf8).write(to: cached, options: .atomic)
  #expect(await icons.image(for: .init(paths: [cached.path], scope: scope)) == nil)
  let fallback = ExtensionIcons.choices("missing.png", manifest: "globe")
  #expect(fallback.paths == ["missing.png"] && fallback.symbol == "globe")
}

@MainActor @Test func jsonPageItemsUseExtensionImagesAndTagsKeepSymbols() async throws {
  let folder = fixtureURL("image-icons")
  let scope = ExtensionIcons.Scope(folder: folder, data: folder, manifest: "bookmark")
  let page = Page(
    body: #"<row icon="release.png" title="A tagged row" copy="text"/>"#,
    items: [
      Row(id: "note", title: "An appended item", icon: "release.png", actions: []),
      Row(id: "gone", title: "Missing icon", icon: "gone.png", actions: []),
    ], runs: true, iconScope: scope)
  #expect(page.iconRequests.keys.sorted() == ["gone", "note"])
  #expect(page.symbols == ["doc.on.doc", "bookmark"])
  let stylesheet = await PageIcons.extensionStylesheet(for: page)
  #expect(stylesheet.contains(#"[data-target="note"]"#))
  #expect(stylesheet.contains("data:image/png;base64,"))
  #expect(!stylesheet.contains("gone"))
}
