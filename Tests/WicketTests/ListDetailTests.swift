import AppKit
import Foundation
import Testing

@testable import WicketApp

/// An extension of manifest items named Notes, found at the root like apps; the first and last carry a
/// detail.
@MainActor private func notes(in root: URL) async throws -> LauncherModel {
  let folder = root.appending(path: "extensions/notes")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let manifest: [String: Any] = [
    "name": "Notes", "keyword": "notes",
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
  model.input = "note"
  await model.settled()
  #expect(model.results.contains { $0.row.title == "Alpha note" && $0.row.detail != nil })
  #expect(!model.splits && model.preview == nil)
  // Inside the command the first item is selected and its detail shows at once.
  model.go(Address(id: "notes"))
  await model.settled()
  #expect(model.splits && model.selected?.row.id == "alpha")
  let alpha = try #require(model.preview)
  #expect(alpha.page.source.contains("## Alpha") && alpha.turn == "detail:extension:notes:alpha")
  #expect(model.cardHeight(answer: 80, cap: 500) == PaletteLayout.rowsHeight(8) + PaletteLayout.footer)
  // Arrows change what it shows, with no request; an item without a detail shows an empty pane, and the
  // card keeps its height.
  model.move(1)
  #expect(model.preview?.page.source == "" && model.preview?.turn == "detail:extension:notes:beta")
  model.move(1)
  #expect(model.preview?.page.source == "Gamma body")
  #expect(model.cardHeight(answer: 300, cap: 500) == PaletteLayout.rowsHeight(8) + PaletteLayout.footer)
  // Return runs the item's own first action, and ⌘K lists its actions in place of the split.
  model.move(-2)
  #expect(model.returnAction == .copy("alpha") && model.offersActions)
  model.toggleActions()
  #expect(!model.splits && model.results.map(\.row.title) == ["Copy", "Open", "Set Hotkey…"])
  #expect(model.escape() && model.splits && model.selected?.row.id == "alpha")
  // Typing filters as in any list; a list left without details is a plain list.
  model.input = "beta"
  await model.settled()
  #expect(model.results.map(\.row.title) == ["Beta note"] && !model.splits)
  // A conversation over the command shows no detail.
  model.input = ""
  await model.settled()
  model.askAgent()
  #expect(model.agent.active && !model.splits && model.preview == nil)
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
  // Markdown images and HTML images in a detail never reach the page.
  let detail =
    "![x](data:image/png;base64,iVBORw0KGgo=)\n\n<img src=\"data:image/png;base64,iVBORw0KGgo=\">\n\n<row title=\"T\" icon=\"url(data:x)\"/>"
  let page = Page(body: detail, runs: true)
  #expect(page.picture == nil)
  let html = AnswerMarkdown.html(page.source, streaming: false)
  // Raw HTML becomes an inert element whose attributes are data.
  #expect(!html.contains("<img") && !html.contains(" src="))
  #expect(!PageIcons.stylesheet(for: page).contains("data:image/png;base64,iVBOR"))
  #expect(await PageIcons.picture(page.picture) == "")
}

@MainActor @Test func aPictureIsDrawnDownscaledAsAHostRule() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let large = folder.appending(path: "large.png")
  try testImage(2000, 1000).write(to: large)
  let rule = await PageIcons.picture(large)
  // At most 720 pixels on the longer side, drawn at half that in points; never enlarged.
  #expect(
    rule.hasPrefix("main::before") && rule.contains("min(100%, 360.0px)") && rule.contains("360.0 / 180.0"))
  #expect(rule.contains("url(data:image/png;base64,"))
  let small = folder.appending(path: "small.png")
  try testImage(40, 20).write(to: small)
  #expect(await PageIcons.picture(small).contains("min(100%, 20.0px)"))
  // A missing file draws nothing.
  #expect(await PageIcons.picture(folder.appending(path: "gone.png")) == "")
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
  model.go(Address(extensionName: "clipboard"))
  #expect(model.command?.id == "clipboard" && model.splits)
  // The newest clip is selected, so its detail shows as the history opens.
  #expect(model.selected?.row.title == "let a = \"``\"")
  let shown = try #require(model.preview?.page)
  // The text is one literal code block, its fence longer than any backtick run, then quiet properties.
  #expect(shown.source.hasPrefix("`````\n" + text + "\n`````\n\n"))
  #expect(shown.targets.isEmpty && shown.picture == nil)
  #expect(shown.source.contains("<row label=\"Lines\" value=\"4\"/>"))
  #expect(shown.source.contains("<row label=\"Characters\" value=\"\(text.count)\"/>"))
  let html = AnswerMarkdown.html(shown.source, streaming: false)
  #expect(html.contains("&lt;row title=&quot;Injected&quot;") && !html.contains("<w-row title=\"Injected\""))
  // The image's detail is its picture, named by the host, and its pixel and file size.
  model.move(1)
  let image = try #require(model.preview?.page)
  let id = try #require(history.clips.last?.id)
  #expect(image.picture == folder.appending(path: id + ".png"))
  #expect(image.source.contains("<row label=\"Dimensions\" value=\"32×24\"/>"))
  #expect(image.source.contains("<row label=\"File size\""))
  #expect(await PageIcons.picture(image.picture).contains("data:image/png;base64,"))
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
  model.go(Address(id: "notes"))
  await model.settled()
  await controller.renderer.settled()
  #expect(controller.renderer.renderedTurn == "detail:extension:notes:alpha")
  model.move(2)
  await controller.renderer.settled()
  #expect(controller.renderer.renderedTurn == "detail:extension:notes:gamma")
  controller.hide()
  await model.finish()
}
