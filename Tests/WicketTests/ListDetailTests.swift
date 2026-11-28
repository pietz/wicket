import AppKit
import Foundation
import Testing

@testable import WicketApp

/// An extension of manifest items named Notes, found at the root like apps; the first and last carry a
/// detail.
@MainActor private func notes(in root: URL, searchable: Bool = true) async throws -> LauncherModel {
  let folder = root.appending(path: "extensions/notes")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let manifest: [String: Any] = [
    "name": "Notes", "keyword": "notes",
    "fields": searchable ? [["name": "query", "type": "text", "description": "Filter notes"]] : [],
    "items": [
      [
        "id": "alpha", "title": "Alpha note", "detail": "## Alpha\n<row label=\"Owner\" value=\"Ada\"/>",
        "actions": [["type": "copy", "text": "alpha"], ["type": "open", "url": "https://example.com"]],
      ],
      ["id": "beta", "title": "Beta note", "actions": [["type": "copy", "text": "beta"]]],
      ["id": "gamma", "title": "Gamma note", "detail": "Gamma body", "actions": []],
    ],
  ]
  try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  return model
}

@MainActor @Test func aCommandsListWithDetailsShowsTheSelectedOnesBesideIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await notes(in: root)
  // At the root the same items are rows like apps, with no detail beside them.
  model.navigator.input = "note"
  await model.navigator.settled()
  #expect(model.navigator.results.contains { $0.row.title == "Alpha note" && $0.row.detail != nil })
  #expect(!model.navigator.splits && model.navigator.preview == nil)
  // Inside the command the first item is selected and its detail shows at once.
  model.navigator.go(Address(id: "notes"))
  await model.navigator.settled()
  #expect(model.navigator.splits && model.navigator.selected?.row.id == "alpha")
  let alpha = try #require(model.navigator.preview)
  #expect(alpha.page.source.contains("## Alpha") && alpha.turn == "detail:extension:notes:alpha")
  #expect(
    PaletteLayout.cardHeight(model.navigator.presentation, answer: 80, cap: 500) == PaletteLayout.rowsHeight(
      8)
      + PaletteLayout.footer)
  // Arrows change what it shows, with no request; an item without a detail shows an empty pane, and the
  // card keeps its height.
  model.navigator.move(1)
  #expect(
    model.navigator.preview?.page.source == ""
      && model.navigator.preview?.turn == "detail:extension:notes:beta")
  model.navigator.move(1)
  #expect(model.navigator.preview?.page.source == "Gamma body")
  #expect(
    PaletteLayout.cardHeight(model.navigator.presentation, answer: 300, cap: 500) == PaletteLayout.rowsHeight(
      8)
      + PaletteLayout.footer)
  // Return runs the item's own first action, and ⌘K lists its actions in place of the split.
  model.navigator.move(-2)
  #expect(model.navigator.returnAction == .copy("alpha") && model.navigator.offersActions)
  model.navigator.toggleActions()
  #expect(
    !model.navigator.splits && model.navigator.results.map(\.row.title) == ["Copy", "Open", "Set Hotkey…"])
  #expect(model.navigator.escape() && model.navigator.splits && model.navigator.selected?.row.id == "alpha")
  // Typing filters as in any list; a list left without details is a plain list.
  model.navigator.input = "beta"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Beta note"] && !model.navigator.splits)
  // A conversation over the command shows no detail.
  model.navigator.input = ""
  await model.navigator.settled()
  model.navigator.askAgent()
  #expect(model.agent.active && !model.navigator.splits && model.navigator.preview == nil)
  await model.finish()
}

@MainActor @Test func anAddressSelectsTheFirstSplitRowWhenTheInputBelongsToTheAgent() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await notes(in: root, searchable: false)
  model.navigator.go(try #require(Address(url: URL(string: "wicket://notes")!)))
  await model.navigator.settled()
  #expect(model.navigator.splits && model.navigator.selected?.row.id == "alpha")
  #expect(model.navigator.preview?.page.source.contains("## Alpha") == true)
  model.navigator.editInput("Summarize these notes")
  #expect(model.navigator.selection == nil && model.navigator.returnAsksAgent)
  await model.finish()
}

@MainActor @Test func onAPageAnItemsDetailOpensWithReturnLikeARows() async throws {
  let view = ProviderView(
    body: "## Week",
    items: [
      Row(id: "tue", title: "Tuesday", actions: [.copy("tue")], detail: "Rain all day"),
      Row(id: "wed", title: "Wednesday", actions: [.copy("wed")]),
    ])
  let page = Page(body: try #require(view.body), items: view.items, runs: true)
  #expect(page.targets[0].actions == [RowAction(.detail("## Tuesday\n\nRain all day")), .copy("tue")])
  #expect(page.targets[1].actions == [.copy("wed")])
  // The decoded item carries it; the encoded one too, so the agent's context sees it.
  let json = #"{"id":"a","title":"A","actions":[],"detail":"**Bold**"}"#
  let row = try JSONDecoder().decode(Row.self, from: Data(json.utf8))
  #expect(row.detail == "**Bold**")
  #expect(String(decoding: try JSONEncoder().encode(row), as: UTF8.self).contains("**Bold**"))
}

@MainActor @Test func extensionMarkdownCannotShowImages() async throws {
  // Only the host sets a picture: the key is never decoded from an item.
  let json = #"{"id":"a","title":"A","actions":[],"detail":"x","picture":"file:///System/Library/x.png"}"#
  let row = try JSONDecoder().decode(Row.self, from: Data(json.utf8))
  #expect(row.picture == nil)
  #expect(
    !String(
      decoding: try JSONEncoder().encode(
        Row(id: "b", title: "B", actions: [], picture: URL(filePath: "/tmp/b.png"))), as: UTF8.self
    ).contains("picture"))
  // Markdown images are omitted and HTML image tags display as text.
  let detail =
    "![x](data:image/png;base64,iVBORw0KGgo=)\n\n<img src=\"data:image/png;base64,iVBORw0KGgo=\">\n\n<row title=\"T\" icon=\"url(data:x)\"/>"
  let page = Page(body: detail, runs: true)
  #expect(page.picture == nil)
  let blocks = PageDocument(page, turn: "t", streaming: false).blocks
  #expect(
    blocks.map(\.renderedText) == [
      #"<img src="data:image/png;base64,iVBORw0KGgo=">"#, "T",
    ])
}

@MainActor @Test func aPictureMeasuresBeforeItsThumbnailLoads() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let large = folder.appending(path: "large.png")
  try testImage(2000, 1000).write(to: large)
  #expect(PagePictures.picture(large)?.size == CGSize(width: 360, height: 180))
  let renderer = NativePageRenderer()
  renderer.update(Page(body: "", runs: false, picture: large), turn: "picture")
  #expect(renderer.contentHeight == 224)
  let thumbnail = await PagePictures.thumbnail(large)?.value
  #expect(thumbnail?.width == 720 && thumbnail?.height == 360)
  let small = folder.appending(path: "small.png")
  try testImage(40, 20).write(to: small)
  #expect(PagePictures.picture(small)?.size == CGSize(width: 20, height: 10))
  #expect(PagePictures.picture(folder.appending(path: "gone.png")) == nil)
}

@MainActor @Test func clipboardHistoryShowsTheNewestClipsDetailAtOnce() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let history = ClipboardHistory(
    url: folder.appending(path: "clipboard-history.json"), pasteboard: FakePasteboard(), interval: nil)
  history.configure(enabled: true)
  await history.capture(image: testImage(32, 24))
  let text = "let a = \"``\"\n```swift\n<row title=\"Injected\" copy=\"x\"/>\n````"
  history.capture(text)
  let model = LauncherModel(
    clipboard: history, history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder)
  model.store.start(watching: false)
  model.store.update { $0.providers = [.init("clipboard")] }
  model.navigator.go(Address(extensionName: "clipboard"))
  #expect(model.navigator.command?.id == "clipboard" && model.navigator.splits)
  // The newest clip is selected, so its detail shows as the history opens.
  #expect(model.navigator.selected?.row.title == "let a = \"``\"")
  let shown = try #require(model.navigator.preview?.page)
  // The text is one literal code block, its fence longer than any backtick run, then quiet properties.
  #expect(shown.source.hasPrefix("`````\n" + text + "\n`````\n\n"))
  #expect(shown.targets.isEmpty && shown.picture == nil)
  #expect(shown.source.contains("<row label=\"Lines\" value=\"4\"/>"))
  #expect(shown.source.contains("<row label=\"Characters\" value=\"\(text.count)\"/>"))
  #expect(PageDocument(shown, turn: "t", streaming: false).blocks.first == .code(text, target: nil))
  // The image's detail is its picture, named by the host, and its pixel and file size.
  model.navigator.move(1)
  let image = try #require(model.navigator.preview?.page)
  let id = try #require(history.clips.last?.id)
  #expect(image.picture == folder.appending(path: id + ".png"))
  #expect(image.source.contains("<row label=\"Dimensions\" value=\"32×24\"/>"))
  #expect(image.source.contains("<row label=\"File size\""))
  #expect(await PagePictures.thumbnail(try #require(image.picture))?.value != nil)
  await model.finish()
}

@Test func aLongTextsDetailShowsItsBeginning() {
  let lines = (1...500).map { "line \($0)" }.joined(separator: "\n")
  let detail = ClipboardHistory.detail(lines, lines: 500, age: "now")
  #expect(detail.contains("line 200\n```") && !detail.contains("line 201"))
  #expect(detail.contains("Shows the beginning") && detail.contains("value=\"500\""))
  let long = String(repeating: "x", count: 20_000)
  #expect(ClipboardHistory.detail(long, lines: 1, age: "now").count < 6000)
  #expect(!ClipboardHistory.detail("short", lines: 1, age: "now").contains("Shows the beginning"))
}

/// The panel draws the selected item's detail: each arrow key renders the new one in the shared canvas.
@MainActor @Test func arrowsRenderTheSelectedDetailInTheCanvas() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await notes(in: root)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.go(Address(id: "notes"))
  await model.navigator.settled()
  #expect(controller.renderer.renderedTurn == "detail:extension:notes:alpha")
  model.navigator.move(2)
  #expect(controller.renderer.renderedTurn == "detail:extension:notes:gamma")
  controller.hide()
  await model.finish()
}

@MainActor @Test func doubleClickingARowWithNothingToRunStillShowsItsDetail() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await notes(in: root)
  model.navigator.go(Address(id: "notes"))
  await model.navigator.settled()
  try #require(model.navigator.selected?.row.id == "alpha")
  let gamma = try #require(model.navigator.results.first { $0.row.id == "gamma" })
  model.navigator.runRow(gamma)
  #expect(model.navigator.selected?.row.id == "gamma")
  #expect(model.navigator.preview?.page.source == "Gamma body")
  await model.finish()
}
