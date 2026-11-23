import Foundation
import Testing

@testable import WicketApp

private let links = "extension:links-search"
private let web = "extension:web"

@MainActor
@Test(arguments: [
  ("yt cats", "youtube", "cats"),
  ("wiki new york", "wikipedia", "new york"),
  ("gh swift testing", "github", "swift testing"),
])
func headlessSiteKeywordsFillTheOriginalQuery(_ input: String, id: String, query: String) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try saveProviders([.init(links), .init(web)], in: root)
  let (status, output) = try await cli(root, ["--query", input])
  let rows = output["items"].array
  let first = try #require(rows.first)
  let row = first["row"]
  let action = try #require(row["actions"].array.first)
  #expect(status == 0 && output["input"].string == input)
  #expect(first["provider"].string == links && row["id"].string == "item:" + id)
  #expect(row["subtitle"].string == query)
  #expect(action["action"].string == "open-link")
  #expect(action["fields"]["query"].string == query && action["fields"]["link"].string == id)
  #expect(!rows.contains { $0["row"]["id"].string == "fallback" })
  #expect(rows.contains { $0["provider"].string == "agent" })
}

@MainActor @Test func bundledWebFallbackOnlyAppearsForWeakNonemptyQueriesWhenEnabled() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try saveProviders([.init(links), .init(web)], in: root)
  let text = "how do curious cats find their way home"
  let (status, output) = try await cli(root, ["--query", text])
  let rows = output["items"].array
  #expect(status == 0)
  #expect(rows.first?["provider"].string == "agent")
  let row = try #require(rows.dropFirst().first?["row"])
  #expect(row["id"].string == "fallback" && row["title"].string == "Search the Web")
  let action = try #require(row["actions"].array.first)
  #expect(action["input"].string == text && action["hidden"] == .bool(true))
  for input in ["", "wiki", "web curious cats"] {
    let result = try await cli(root, ["--query", input]).1
    #expect(!result["items"].array.contains { $0["row"]["id"].string == "fallback" }, "\(input)")
    if input.hasPrefix("web ") {
      let first = try #require(result["items"].array.first)
      #expect(first["provider"].string == web && first["row"]["subtitle"].string == "curious cats")
    }
  }
  try saveProviders([.init(links)], in: root)
  let disabled = try await cli(root, ["--query", text]).1
  #expect(!disabled["items"].array.contains { $0["provider"].string == web })
}

/// Compile the shipped request handlers with an inert Launch Services stand-in. The same binary
/// answers CLI and navigator requests without requiring a runtime test switch in the extension.
@MainActor private func installLinkProbe(_ name: String, in root: URL) async throws -> URL {
  let folder = root.appending(path: "extensions/" + name)
  try FileManager.default.createDirectory(
    at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: bundledExtensions.appending(path: name), to: folder)
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
  let folder = try await installLinkProbe("links-search", in: root)
  let direct = try await cli(
    root,
    [
      "--extension", "links-search", "--submitted", "--action", "open-link", "--input", "new york",
      "--fields",
      try fields(["link": "wikipedia"]),
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
      try fields(["link": "youtube"]),
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
  let listing = try await cli(root, ["--extension", "links-search"])
  #expect(listing.1["items"].array.map { $0["id"].string } == ["youtube", "wikipedia", "github"])
  let filtered = try await cli(root, ["--extension", "links-search", "--input", "yt"])
  #expect(filtered.1["items"].array.map { $0["id"].string } == ["youtube"])
  #expect(!didOpenURL(in: folder))
}

@MainActor @Test func webUsesTheSavedEngineAndOpensOnlyOnSubmission() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await installLinkProbe("web", in: root)
  let preview = try await cli(root, ["--extension", "web", "--input", "cats & dogs"])
  #expect(preview.0 == 0 && !didOpenURL(in: folder))
  let empty = try await cli(root, ["--extension", "web", "--submitted", "--input", " "])
  #expect(empty.1["items"].array.first?["title"].string == "Enter a search query.")
  #expect(!didOpenURL(in: folder))
  let submitted = try await cli(root, ["--extension", "web", "--submitted", "--input", " cats & dogs "])
  #expect(submitted.0 == 0 && submitted.1 == .object([:]))
  #expect(try takeOpenedURL(in: folder) == "https://duckduckgo.com/?q=%20cats%20%26%20dogs%20")

  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  let surface = RecordingSurface()
  model.navigator.surface = surface
  await model.extensions.reload()
  model.navigator.input = "how do curious cats find their way home"
  await model.navigator.settled()
  let fallback = try #require(model.navigator.results.dropFirst().first)
  #expect(fallback.provider == web && fallback.row.id == "fallback" && !didOpenURL(in: folder))
  model.navigator.runRow(fallback)
  await model.navigator.settled()
  #expect(
    try takeOpenedURL(in: folder)
      == "https://duckduckgo.com/?q=how%20do%20curious%20cats%20find%20their%20way%20home"
  )
  await model.finish()

  var config = Configuration()
  config.extensions = ["web": ["webEngine": "Google"]]
  try config.save(at: root.appending(path: "config.json"))
  let changed = try await cli(root, ["--extension", "web", "--submitted", "--input", "cats"])
  #expect(changed.0 == 0)
  #expect(try takeOpenedURL(in: folder) == "https://www.google.com/search?q=cats")
}

@MainActor @Test func linksRunThroughReturnTabAndItemHotkeys() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await installLinkProbe("links-search", in: root)
  try Data(
    #"""
    {"items":[
      {"id":"mdn","title":"MDN Web Docs","keywords":["mdn"],"actions":[{"type":"open","url":"https://developer.mozilla.org/"}]},
      {"id":"docs","title":"Search Docs","keywords":["docs"],"subtitle":"Test Browser","actions":[
        {"type":"run","action":"open-link","input":"","fields":{"template":"https://example.com/search?q={query}","bundleID":"test.browser"},"hidden":true}]},
      {"id":"missing","title":"Search Archive","keywords":["archive"],"actions":[
        {"type":"run","action":"open-link","input":"","fields":{"template":"https://example.com/search?q={query}","bundleID":"missing.browser"},"hidden":true}]},
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

  let youtube = HotkeyTarget(target: links, item: "youtube")
  let docs = HotkeyTarget(target: links, item: "docs", isUserItem: true)
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
  #expect(navigator.results.first?.row.id == "user-item:docs")
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=swift%20ui\n/Probe.app")

  await type("fixed")
  #expect(navigator.fieldSlots.isEmpty)
  navigator.run()
  await navigator.settled()
  #expect(try takeOpenedURL(in: folder) == "https://example.com/search?q=fixed%20value")

  await type("archive keep this query")
  navigator.run()
  await navigator.settled()
  #expect(navigator.command?.id == links && navigator.input == "keep this query")
  #expect(navigator.results.first?.row.title.contains("missing.browser") == true && !didOpenURL(in: folder))
  navigator.dismiss()
  await navigator.settled()

  await type("mdn")
  let bookmark = try #require(navigator.results.first)
  #expect(bookmark.row.id == "user-item:mdn")
  let action = RowAction.open(try #require(URL(string: "https://developer.mozilla.org/")))
  navigator.run()
  #expect(surface.effects.last == .run(action, from: bookmark))
  model.press(HotkeyTarget(target: links, item: "mdn", isUserItem: true))
  #expect(surface.effects.last == .run(action, from: nil))
  await model.finish()
}
