import Foundation
import Testing

@testable import WicketApp

private let links = "extension:links-search"

@MainActor
@Test(arguments: [
  ("yt cats", "youtube", "cats"),
  ("wiki new york", "wiki", "new york"),
])
func headlessSiteKeywordsFillTheOriginalQuery(_ input: String, id: String, query: String) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try saveProviders([.init(links)], in: root)
  try writeQuicklinks(in: root)
  let (status, output) = try await cli(root, ["--query", input])
  let rows = output["items"].array
  let first = try #require(rows.first)
  let row = first["row"]
  let action = try #require(row["actions"].array.first)
  #expect(status == 0 && output["input"].string == input)
  #expect(first["provider"].string == links && row["id"].string == "entry:searches/" + id)
  #expect(row["subtitle"].string == "Quicklinks · " + query)
  #expect(action["promptIfEmpty"] == .bool(true))
  #expect(action["action"].string == "open-link")
  #expect(
    action["fields"]["query"].string == query
      && action["fields"]["template"].string?.contains("{query}") == true)
  #expect(!rows.contains { $0["row"]["id"].string == "fallback" })
  #expect(rows.contains { $0["provider"].string == "agent" })
}

@MainActor @Test func quicklinksStartsEmptyAndListsOnlySavedLinks() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try saveProviders([.init(links)], in: root)
  let empty = try await cli(root, ["--extension", "links-search"])
  let help = try #require(empty.1["items"].array.first)
  #expect(help["title"].string == "Add a Quicklink…")
  let unknown = try await cli(root, ["--query", "yt cats"])
  #expect(!unknown.1["items"].array.contains { $0["provider"].string == links })

  try writeQuicklinks(in: root)
  let listing = try await cli(root, ["--extension", "links-search"])
  let items = listing.1["items"].array
  #expect(items.count == 2)
  #expect(items.compactMap { $0["id"].string }.sorted() == ["entry:searches/wiki", "entry:searches/youtube"])
  let filtered = try await cli(root, ["--extension", "links-search", "--input", "yt"])
  #expect(filtered.1["items"].array.map { $0["id"].string } == ["entry:searches/youtube"])
}

@MainActor @Test(arguments: [false, true])
func aLocalQuicklinksProgramRendersItsOwnView(makeMine: Bool) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  let navigator = model.navigator
  await model.extensions.reload()

  if makeMine {
    try model.extensions.makeMine(try #require(model.extensions.commands[links]))
    await model.extensions.reload()
    navigator.go(Address(id: links, link: true))
    await navigator.settled()
    #expect(navigator.results.first?.row.id == "add-quicklink")
    navigator.dismiss()
  }

  let title = "My Quicklinks view"
  _ = try extensionFolder(root, name: "links-search", script: answering(title))
  await model.extensions.reload()
  navigator.go(Address(id: links, link: true))
  await navigator.settled()
  #expect(navigator.results.map(\.row.title) == [title])
  let (status, output) = try await cli(root, ["--extension", "links-search"])
  #expect(status == 0 && output["items"].array.first?["title"].string == title)
  await model.finish()
}

let quicklinkSearches = [
  [
    "id": "youtube", "title": "Search YouTube", "keyword": "yt",
    "url": "https://www.youtube.com/results?search_query={query}",
  ],
  [
    "id": "wiki", "title": "Search Wikipedia", "keyword": "wiki",
    "url": "https://en.wikipedia.org/w/index.php?search={query}",
  ],
]

func writeQuicklinks(in root: URL) throws {
  let url = root.appending(path: "config.json")
  if !FileManager.default.fileExists(atPath: url.path) { try Configuration().save(at: url) }
  try ConfigurationFile(url: url).set("links-search", to: ["searches": quicklinkSearches], in: "extensions")
}

/// Compile the shipped request handlers with an inert Launch Services stand-in. The same binary
/// answers CLI and navigator requests without requiring a runtime test switch in the extension.
@MainActor private func installLinkProbe(in root: URL) async throws -> URL {
  let folder = root.appending(path: "extensions/links-search")
  try FileManager.default.createDirectory(
    at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: bundledExtensions.appending(path: "links-search"), to: folder)
  let binary = folder.appending(path: "main")
  try FileManager.default.removeItem(at: binary)
  let compiled = try await Launch.capture(
    URL(filePath: "/usr/bin/xcrun"),
    [
      "swiftc", "-warnings-as-errors", "-swift-version", "6", "main.swift", "SearchURL.swift", "JSON.swift",
      fixtureURL("BrowserOpenerProbe.swift").path, "-o", binary.path,
    ], in: folder, limit: .seconds(30))
  guard compiled?.exit.isClean == true else { throw ExtensionFailure("Could not build the link probe") }
  return folder
}

private func takeOpenedURL(in folder: URL) throws -> String {
  let file = folder.appending(path: "opened")
  let value = try String(contentsOf: file, encoding: .utf8)
  try FileManager.default.removeItem(at: file)
  return value
}

private func didOpenURL(in folder: URL) -> Bool {
  FileManager.default.fileExists(atPath: folder.appending(path: "opened").path)
}

private func fields(_ values: [String: String]) throws -> String {
  String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
}

@MainActor @Test func headlessLinksValidateTemplatesAndSendOnlySubmittedURLsToTheRightApp() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await installLinkProbe(in: root)
  let direct = try await cli(
    root,
    [
      "--extension", "links-search", "--submitted", "--action", "open-link", "--input", "new york",
      "--fields",
      try fields(["template": "https://en.wikipedia.org/w/index.php?search={query}"]),
    ])
  #expect(direct.0 == 0 && direct.1 == .object([:]))
  #expect(try takeOpenedURL(in: folder) == "https://en.wikipedia.org/w/index.php?search=new%20york")

  let template = "https://example.com/find/{query}/tail?format=two%20words&q=pre{query}#section"
  let raw = "a/b & #%+ café"
  let selected = try fields(["template": template, "query": raw, "bundleID": "test.browser"])
  let unsubmitted = try await cli(root, ["--extension", "links-search", "--fields", selected])
  #expect(unsubmitted.0 == 0 && !didOpenURL(in: folder))
  let submitted = try await cli(
    root,
    [
      "--extension", "links-search", "--submitted", "--action", "open-link", "--fields", selected,
    ])
  #expect(submitted.0 == 0 && submitted.1 == .object([:]))
  let opened = try takeOpenedURL(in: folder)
  // macOS process arguments can arrive in decomposed Unicode.
  let expected = ["caf%C3%A9", "cafe%CC%81"].map { name in
    let encoded = "a%2Fb%20%26%20%23%25%2B%20" + name
    return "https://example.com/find/\(encoded)/tail?format=two%20words&q=pre\(encoded)#section\n/Probe.app"
  }
  #expect(expected.contains(opened))

  let staticFields = try fields(["template": "https://example.com/docs", "bundleID": "test.browser"])
  _ = try await cli(root, ["--extension", "links-search", "--fields", staticFields])
  #expect(!didOpenURL(in: folder))
  _ = try await cli(
    root,
    [
      "--extension", "links-search", "--submitted", "--action", "open-link", "--fields", staticFields,
    ])
  #expect(try takeOpenedURL(in: folder) == "https://example.com/docs\n/Probe.app")

  let empty = try await cli(
    root,
    [
      "--extension", "links-search", "--submitted", "--action", "open-link", "--fields",
      try fields(["template": "https://www.youtube.com/results?search_query={query}"]),
    ])
  #expect(empty.1["items"].array.first?["title"].string == "Enter a search query.")
  #expect(!didOpenURL(in: folder))

  for invalid in [
    "file:///etc/{query}", "https://user@example.com/?q={query}", "https://{query}.example.com/",
    "https://example.com/?{query}=foo", "https://example.com/#{query}", "https://example.com/?{query}",
    "https://example.com/%2e%2e?q={query}", "https://example.com/?q=%oops{query}", "https:///missing-host",
    "https://example.com/{query}", "https://example.com:99999/?q={query}",
  ] {
    let result = try await cli(
      root,
      [
        "--extension", "links-search", "--submitted", "--action", "open-link", "--input", "..",
        "--fields", try fields(["template": invalid]),
      ])
    #expect(result.1["items"].array.first?["id"].string == "status", "\(invalid)")
    #expect(!didOpenURL(in: folder), "\(invalid)")
  }
}

@MainActor @Test func linksRunThroughReturnTabAndItemHotkeys() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await installLinkProbe(in: root)
  try Data(
    #"""
    {"items":[
      {"id":"mdn","title":"MDN Web Docs","keyword":"mdn","url":"https://developer.mozilla.org/"},
      {"id":"youtube","title":"Search YouTube","keyword":"yt","url":"https://www.youtube.com/results?search_query={query}"},
      {"id":"docs","title":"Search Docs","keywords":["docs"],"subtitle":"Test Browser","actions":[
        {"type":"run","action":"open-link","promptIfEmpty":true,"fields":{"template":"https://example.com/search?q={query}","bundleID":"test.browser"},"hidden":true}]},
      {"id":"missing","title":"Search Archive","keywords":["archive"],"actions":[
        {"type":"run","action":"open-link","promptIfEmpty":true,"fields":{"template":"https://example.com/search?q={query}","bundleID":"missing.browser"},"hidden":true}]},
      {"id":"fixed","title":"Saved Search","keywords":["fixed"],"actions":[
        {"type":"run","action":"open-link","input":"","fields":{"template":"https://example.com/search?q={query}","query":"fixed value"},"hidden":true}]}
    ]}
    """#.utf8
  ).write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  surface.onEffect = { if $0 == .hide { navigator.dismiss() } }
  model.store.start(watching: false)
  await model.extensions.reload()
  func type(_ input: String) async {
    navigator.input = input
    await navigator.settled()
  }

  await type("yt cats")
  #expect(!didOpenURL(in: folder))
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://www.youtube.com/results?search_query=cats")

  await type("yt")
  #expect(navigator.moveFocus(1) && navigator.focusedField == "query")
  navigator.setField("query", to: "dogs")
  #expect(!didOpenURL(in: folder))
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://www.youtube.com/results?search_query=dogs")

  let youtube = HotkeyTarget(target: links, item: "youtube", entryList: "searches")
  let docs = HotkeyTarget(target: "extension:my-items", item: "docs")
  model.press(docs)
  await navigator.settled()
  #expect(navigator.command?.id == links && navigator.input.isEmpty && !didOpenURL(in: folder))
  await type("swift testing")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=swift%20testing\n/Probe.app")

  // A second hotkey from an open link starts with its own fixed fields.
  model.press(docs)
  await navigator.settled()
  await type("unsent query")
  model.press(youtube)
  await navigator.settled()
  #expect(navigator.command?.id == links && navigator.input.isEmpty && !didOpenURL(in: folder))
  await type("new cats")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://www.youtube.com/results?search_query=new%20cats")

  await type("docs swift ui")
  #expect(navigator.results.first?.row.id == "item:docs")
  #expect(navigator.results.first?.row.subtitle == "Test Browser · swift ui")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=swift%20ui\n/Probe.app")

  await type("fixed")
  #expect(navigator.fieldSlots.isEmpty)
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=fixed%20value")

  model.press(youtube)
  await navigator.settled()
  try #require(navigator.command?.id == links && surface.isShown && navigator.input.isEmpty)
  #expect(
    navigator.fieldValues["template"] == "https://www.youtube.com/results?search_query={query}"
      && !didOpenURL(in: folder))
  await type("unsent YouTube query")
  model.press(HotkeyTarget(target: "extension:my-items", item: "fixed"))
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=fixed%20value")

  await type("archive keep this query")
  navigator.run()
  await navigator.settled()
  #expect(navigator.command?.id == links && navigator.input == "keep this query")
  #expect(navigator.results.first?.row.title.contains("missing.browser") == true && !didOpenURL(in: folder))
  navigator.dismiss()
  await navigator.settled()

  await type("mdn javascript")
  #expect(navigator.results.allSatisfy { $0.provider != links || $0.keywordArgument == nil })
  await type("mdn")
  #expect(navigator.fieldSlots.isEmpty)
  let bookmark = try #require(navigator.results.first)
  #expect(bookmark.row.id == "entry:links/mdn")
  let action = RowAction.open(try #require(URL(string: "https://developer.mozilla.org/")))
  navigator.run()
  #expect(surface.effects.last == .run(action, from: bookmark))
  model.press(HotkeyTarget(target: links, item: "mdn", entryList: "links"))
  #expect(surface.effects.last == .run(action, from: nil))
  await model.finish()
}

@MainActor @Test func migratedEntriesKeepRootSearchAndHotkeys() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let bundled = try await installLinkProbe(in: root.appending(path: "bundle"))
  let local = root.appending(path: "extensions/links-search")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  try Data(
    #"""
    {"items":[
      {"id":"mdn","title":"MDN Web Docs","keyword":"mdn","url":"https://developer.mozilla.org/"},
      {"id":"osm","title":"Search OpenStreetMap","keyword":"osm","url":"https://www.openstreetmap.org/search?query={query}"}
    ]}
    """#.utf8
  ).write(to: local.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: bundled.deletingLastPathComponent())
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  model.store.start(watching: false)
  await model.extensions.reload()
  let command = try #require(model.extensions.commands[links])
  #expect(model.extensions.isBundled(command))

  navigator.go(Address(id: links, link: true))
  await navigator.settled()
  #expect(navigator.results.count == 2)
  navigator.editInput("osm")
  await navigator.settled()
  let search = try #require(navigator.results.first)
  #expect(search.row.id == "entry:searches/osm")
  #expect(
    navigator.hotkeyTarget(of: search) == HotkeyTarget(target: links, item: "osm", entryList: "searches"))
  navigator.dismiss()

  navigator.input = "mdn"
  await navigator.settled()
  let bookmark = RowAction.open(try #require(URL(string: "https://developer.mozilla.org/")))
  #expect(navigator.results.first?.row.id == "entry:links/mdn")
  #expect(navigator.returnAction == bookmark)
  model.press(try #require(HotkeyTarget("wicket://links-search?entry=links/mdn")))
  #expect(surface.effects.last == .run(bookmark, from: nil))

  navigator.input = "osm New York"
  await navigator.settled()
  #expect(navigator.results.first?.row.id == "entry:searches/osm")
  #expect(navigator.results.first?.row.subtitle == "Quicklinks · New York")

  surface.shown = false
  navigator.dismiss()
  model.press(try #require(HotkeyTarget("wicket://links-search?entry=searches/osm")))
  await navigator.settled()
  #expect(surface.shows == 1 && navigator.command?.id == links && navigator.input.isEmpty)
  try #require(navigator.commandPlaceholder == "Search query" && !didOpenURL(in: bundled))
  navigator.editInput("New York")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: bundled) == "https://www.openstreetmap.org/search?query=New%20York")
  #expect(try FileManager.default.contentsOfDirectory(atPath: local.path) == ["user.json"])
  await model.finish()
}

@MainActor @Test func youtubeHotkeyShowsQueryOverAKeptConversation() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await installLinkProbe(in: root)
  try writeQuicklinks(in: root)
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  surface.onEffect = { if $0 == .hide { navigator.dismiss() } }
  model.store.load()
  await model.extensions.reload()
  try await finishTurn(model, "Question", "Answer")
  navigator.editInput("Unsent follow-up")
  surface.perform(.hide)
  try #require(model.agent.active && !surface.isShown)

  model.press(HotkeyTarget(target: links, item: "youtube", entryList: "searches"))
  #expect(surface.shows == 1 && navigator.commandPlaceholder == "Search query" && !model.agent.active)
  await navigator.settled()
  #expect(navigator.input.isEmpty && navigator.results.first?.row.title == "Enter a search query.")
  #expect(!didOpenURL(in: folder))

  navigator.editInput("swift")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://www.youtube.com/results?search_query=swift")
  await model.finish()
}
