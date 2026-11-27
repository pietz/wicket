import CoreGraphics
import Darwin
import Foundation
import Testing
import WebKit

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
  func image(_ paths: [String]) async -> CGImage? {
    let request = ExtensionIcons.Request(paths: paths, scope: scope)
    return await ExtensionIcons.load(request.version).image
  }

  for path in ["bundled.PNG", "internal.png", bundled.path, cached.path] {
    #expect(await image([path]) != nil)
  }
  for path in [
    foreign.path, "../extension-other/foreign.png", "escape.png", "cache.png", "wrong-type.svg",
    "broken.png", "missing.png", cached.absoluteString, "https://example.com/icon.png", "wide.svg.",
  ] {
    #expect(await image([path]) == nil)
    let choices = ExtensionIcons.choices(path, manifest: scope.manifest)
    let fallback = try #require(await image(choices.paths))
    #expect(fallback.width == 78 && fallback.height == 39)
  }

  try Data("no longer an image".utf8).write(to: cached, options: .atomic)
  #expect(await image([cached.path]) == nil)
  let fallback = ExtensionIcons.choices("missing.png", manifest: "globe")
  #expect(fallback.paths == ["missing.png"] && fallback.symbol == "globe")
}

@MainActor @Test func jsonPageItemsUseExtensionImagesAndTagsKeepSymbols() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  try FileManager.default.copyItem(
    at: fixtureURL("image-icons/release.png"), to: folder.appending(path: "release.png"))
  let scope = ExtensionIcons.Scope(folder: folder, data: folder, manifest: "bookmark")
  let page = Page(
    body: #"<row icon="release.png" title="A tagged row" copy="text"/>"#,
    items: [
      Row(id: "note", title: "An appended item", icon: "release.png", actions: []),
      Row(id: "other", title: "Another item with the same icon", icon: "release.png", actions: []),
      Row(id: "gone", title: "Missing icon", icon: "gone.png", actions: []),
    ], runs: true, iconScope: scope)
  #expect(page.iconRequests.keys.sorted() == ["gone", "note", "other"])
  #expect(page.symbols == ["doc.on.doc", "bookmark"])
  let versions = page.iconRequests.mapValues(\.version)
  #expect(PageIcons.extensionStylesheet(for: versions).isEmpty)

  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  await renderer.render(page, turn: "images")
  try #require(
    await eventually {
      PageIcons.extensionStylesheet(for: versions).contains("data:image/png;base64,")
    })
  await renderer.settled()
  let webPage = try #require(renderer.page)
  let css = try await webPage.callJavaScript(
    "return document.querySelector('#icons').textContent;", arguments: [:], contentWorld: .defaultClient)
  let stylesheet = try #require(css as? String)
  #expect(stylesheet.contains(#"[data-target="note"], [data-target="other"]"#))
  let extensionCSS = PageIcons.extensionStylesheet(for: versions)
  #expect(stylesheet.hasSuffix(extensionCSS))
  #expect(extensionCSS.components(separatedBy: "data:image/png;base64,").count == 2)
  #expect(!stylesheet.contains("gone"))
}

@Test func extensionIconReadsCheckTheOpenedFileAndCapItsBytes() throws {
  let root = try scratch().resolvingSymlinksInPath()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "icon.png")
  let other = root.appending(path: "other.png")
  let limit = 256 * 1024
  let approved = Data(repeating: 42, count: limit)
  try approved.write(to: file)
  try Data([1, 2, 3]).write(to: other)
  let approvedFD = open(file.path, O_RDONLY)
  defer { close(approvedFD) }
  let otherFD = open(other.path, O_RDONLY)
  defer { close(otherFD) }
  try #require(approvedFD >= 0 && otherFD >= 0)
  let resolved = try #require(realpath(file.path, nil))
  defer { free(resolved) }
  let path = String(cString: resolved)
  #expect(ExtensionIcons.contents(of: otherFD, at: path) == nil)
  #expect(ExtensionIcons.contents(of: approvedFD, at: path) == approved)
  try Data(repeating: 0, count: limit + 1).write(to: file)
  #expect(lseek(approvedFD, 0, SEEK_SET) == 0)
  #expect(ExtensionIcons.contents(of: approvedFD, at: path) == nil)
}

@Test func indexedFileItemsKeepNativeIconsUnlessTheySpecifyAnImage() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "document.txt")
  let items = [
    Row(id: "open", title: "Open Document", actions: [RowAction(.open(file))]),
    Row(id: "reveal", title: "Reveal Document", actions: [RowAction(.reveal(file))]),
    Row(id: "image", title: "Image Document", icon: "explicit.png", actions: [RowAction(.open(file))]),
  ]
  let manifestJSON = """
    {"name":"Documents","icon":"manifest.png","items":\(String(decoding: try JSONEncoder().encode(items), as: UTF8.self))}
    """
  let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(manifestJSON.utf8))
  let command = ExtensionCommand(id: "extension:documents", folder: root, manifest: manifest)
  let rootRows = command.rootItems(SearchQuery("document")).map(\.row)
  let view = try #require(command.staticView(for: ProviderRequest(input: "", submitted: false)))
  for rows in [rootRows, view.items] {
    #expect(rows.count == 3)
    let fileRows = rows.filter { ExtensionIcons.nativeFile(for: $0) == file }
    #expect(Set(fileRows.map(\.title)) == ["Open Document", "Reveal Document"])
    #expect(fileRows.allSatisfy { $0.icon == nil })
  }
  let scope = ExtensionIcons.Scope(folder: root, data: root, manifest: manifest.icon)
  let page = Page(body: "", items: view.items, runs: true, iconScope: scope)
  #expect(page.iconRequests.keys.sorted() == ["image"])
}

@MainActor @Test func changingOnlyAnIconRefreshesItsRequestWithoutChangingTheCatalog() async throws {
  let root = try scratch().resolvingSymlinksInPath()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(root, name: "status", fields: ["icon": "icon.png"])
  let icon = folder.appending(path: "icon.png")
  try FileManager.default.copyItem(at: fixtureURL("image-icons/release.png"), to: icon)
  let host = ExtensionHost(folder: root, bundled: nil)
  host.start()
  await host.firstScan()
  let command = try #require(host.commands["extension:status"])
  let request = ExtensionIcons.Request(paths: ["icon.png"], scope: host.iconScope(for: command))
  let before = request.version
  #expect(await ExtensionIcons.load(before).image != nil)

  var changed: Set<String> = []
  host.onCatalogChange = { changed.formUnion($0) }
  let revision = host.iconRevision
  try Data(contentsOf: fixtureURL("image-icons/favicon.png")).write(to: icon)
  try #require(await eventually(within: .seconds(3)) { host.iconRevision > revision })
  #expect(changed.isEmpty)
  let after = request.version
  #expect(before != after)
  #expect(ExtensionIcons.cached(after) == nil)
  #expect(await ExtensionIcons.load(after).image != nil)
  await host.shutdown()
}
