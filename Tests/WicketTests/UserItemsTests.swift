import Foundation
import Testing

@testable import WicketApp

private func links(in root: URL, stockID: String = "stock") throws -> URL {
  let folder = root.appending(path: "extensions/links")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try Data(
    #"""
    {"name":"Links","icon":"link","fields":[{"name":"query","type":"text","description":"Filter bookmarks"}],"items":[
      {"id":"\#(stockID)","title":"Stock bookmark","actions":[{"type":"copy","text":"stock"}]}
    ]}
    """#.utf8
  ).write(to: folder.appending(path: "wicket.json"))
  return folder.appending(path: "user.json")
}

private func savedBookmark(id: String = "saved", title: String = "Saved bookmark") -> Data {
  Data(#"{"items":[{"id":"\#(id)","title":"\#(title)","actions":[{"type":"copy","text":"saved"}]}]}"#.utf8)
}

@MainActor
@Test(arguments: [
  ("stock", "stock"),
  ("item:stock", "item:item:stock"),
  ("user-item:stock", "item:user-item:stock"),
])
func userItemsJoinManifestItemsAtTheRootAndInTheCommand(_ stockID: String, _ displayedID: String) async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try savedBookmark(id: "stock").write(to: links(in: root, stockID: stockID))
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()

  let id = "extension:links"
  let target = HotkeyTarget(target: id, item: "stock", isUserItem: true)
  let setHotkey = RowAction(.hotkey(target, record: true))
  model.navigator.input = "bookmark"
  await model.navigator.settled()
  let rootRows = model.navigator.results.filter { $0.provider == id }
  #expect(Set(rootRows.map(\.row.id)) == ["item:\(stockID)", "user-item:stock"])
  let saved = try #require(rootRows.first { $0.row.id == "user-item:stock" })
  #expect(saved.row.icon == "link" && saved.row.subtitle == "Links")
  model.navigator.toggleActions(saved)
  #expect(model.navigator.results.contains { $0.row.actions == [setHotkey] })
  model.navigator.toggleActions()

  model.navigator.go(Address(id: id))
  await model.navigator.settled()
  let insideRows = model.navigator.results
  #expect(insideRows.map(\.row.id) == [displayedID, "user-item:stock"])
  let insideStock = try #require(insideRows.first)
  #expect(model.navigator.hotkeyTarget(of: insideStock) == HotkeyTarget(target: id, item: stockID))
  model.navigator.input = "saved"
  await model.navigator.settled()
  let inside = try #require(model.navigator.results.first)
  #expect(model.navigator.results.map(\.row.id) == ["user-item:stock"])
  #expect(model.navigator.actions(of: inside) == [.copy("saved"), setHotkey])
  await model.finish()
}

private func mover(in root: URL) throws -> URL {
  try extensionFolder(
    root, name: "mover", script: "cat >> log.jsonl",
    fields: [
      "items": [
        [
          "id": "work", "title": "Stock layout",
          "actions": [["type": "run", "action": "stock-layout", "hidden": true]],
        ]
      ]
    ])
}

private let userLayout =
  #"""
  {"items":[{"id":"work","title":"My layout","actions":[{"type":"run","action":"my-layout","hidden":true}]}]}
  """#

@MainActor @Test func stockAndUserItemsWithTheSameIDKeepSeparateRowsAndHotkeys() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try mover(in: root)
  try Data(userLayout.utf8).write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  await model.extensions.reload()

  model.navigator.input = "layout"
  await model.navigator.settled()
  let rows = model.navigator.results.filter { $0.provider == "extension:mover" }
  #expect(Set(rows.map(\.row.id)) == ["item:work", "user-item:work"])
  #expect(Set(rows.map(\.id)).count == 2)
  #expect(model.extensions.problems.isEmpty)
  #expect(try requests(in: folder).isEmpty)

  let stockRow = try #require(rows.first { $0.row.title == "Stock layout" })
  let userRow = try #require(rows.first { $0.row.title == "My layout" })
  let stock = try #require(model.navigator.hotkeyTarget(of: stockRow))
  let user = try #require(model.navigator.hotkeyTarget(of: userRow))
  #expect(stock.description == "wicket://mover?item=work")
  #expect(user.description == "wicket://mover?user-item=work")
  #expect(model.navigator.actions(of: userRow).last == RowAction(.hotkey(user, record: true)))

  model.store.bind(try Shortcut("ctrl+option+s"), to: stock)
  model.store.bind(try Shortcut("ctrl+option+u"), to: user)
  let saved = try Configuration.load(at: root.appending(path: "config.json")).hotkeys.map(\.target)
  #expect(saved == [stock, user])
  for target in saved {
    model.press(target)
    await model.navigator.settled()
  }
  let calls = try requests(in: folder)
  #expect(calls.map(\.action) == ["stock-layout", "my-layout"])
  #expect(calls.allSatisfy { $0.submitted })
  #expect(surface.shows == 0 && model.navigator.command == nil)
  await model.finish()
}

@MainActor @Test(arguments: ["{", #"{"items":[],"settings":{}}"#, #"{"items":null}"#])
func invalidUserItemsShowOneRepairWhileManifestItemsStillWork(_ json: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(json.utf8).write(to: links(in: root))
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()

  let id = "extension:links"
  #expect(model.extensions.ids == [id])
  model.navigator.input = "bookmark"
  await model.navigator.settled()
  let rows = model.navigator.results.filter { $0.provider == id }
  #expect(Set(rows.map(\.row.id)) == ["item:stock", "discovery-error"])
  let repairs = rows.filter { $0.row.id == "discovery-error" }
  #expect(repairs.count == 1 && repairs.first?.row.subtitle == "Invalid user.json")
  #expect(model.extensions.problems[id]?.contains("/links/user.json") == true)

  model.navigator.go(Address(id: id))
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.id) == ["stock"])
  #expect(model.navigator.results.first?.row.actions == [.copy("stock")])
  await model.finish()
}

@MainActor @Test func watchingUserItemsRefreshesTheRootAndAnOpenCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let userFile = try links(in: root)
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.extensions.start()
  await model.extensions.firstScan()

  model.navigator.input = "bookmark"
  await model.navigator.settled()
  #expect(model.extensions.problems.isEmpty)
  #expect(model.navigator.results.contains { $0.row.id == "item:stock" })
  try savedBookmark().write(to: userFile, options: .atomic)
  #expect(
    await eventually(within: .seconds(3)) {
      model.navigator.results.contains { $0.row.id == "user-item:saved" }
    })

  model.navigator.go(Address(id: "extension:links"))
  try savedBookmark(title: "New bookmark").write(to: userFile, options: .atomic)
  #expect(await eventually(within: .seconds(3)) { model.navigator.results.last?.row.title == "New bookmark" })
  try FileManager.default.removeItem(at: userFile)
  #expect(await eventually(within: .seconds(3)) { model.navigator.results.map(\.row.id) == ["stock"] })
  #expect(model.extensions.problems.isEmpty)
  await model.finish()
}

@MainActor @Test(arguments: ["saved", ""])
func invalidUserItemIDsRejectTheWholeFile(_ id: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let userFile = try links(in: root)
  try Data(
    """
    {"items":[{"id":"saved","title":"Saved bookmark","actions":[]},{"id":"\(id)","title":"Other","actions":[]}]}
    """.utf8
  ).write(to: userFile)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()

  model.navigator.input = "bookmark"
  await model.navigator.settled()
  let rows = model.navigator.results.filter { $0.provider == "extension:links" }
  #expect(rows.count == 2 && Set(rows.map(\.row.id)) == ["item:stock", "discovery-error"])
  #expect(rows.first { $0.row.id == "discovery-error" }?.row.subtitle == "Invalid user.json")
  #expect(model.extensions.problems["extension:links"]?.contains(Row.invalidIDs) == true)
  await model.finish()
}

@MainActor @Test(arguments: [true, false])
func aRenamedOrRemovedUserItemLeavesItsHotkeyInert(_ rename: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try mover(in: root)
  let userFile = folder.appending(path: "user.json")
  try Data(userLayout.utf8).write(to: userFile)
  let model = LauncherModel.testing(in: root, bundled: nil)
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  await model.extensions.reload()

  let user = try #require(HotkeyTarget("wicket://mover?user-item=work"))
  model.press(user)
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["my-layout"])

  if rename {
    try Data(userLayout.replacingOccurrences(of: #""work""#, with: #""renamed""#).utf8).write(to: userFile)
  } else {
    try FileManager.default.removeItem(at: userFile)
  }
  await model.extensions.reload()
  model.press(user)
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["my-layout"])
  #expect(surface.shows == 1 && model.navigator.command == nil)
  #expect(model.navigator.presentation.footerProblem == "User item “work” is no longer available in mover.")
  await model.finish()
}

@MainActor @Test func anExistingStockHotkeyStillRunsAfterAUserItemReusesItsID() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try mover(in: root)
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  await model.extensions.reload()
  let stock = try #require(HotkeyTarget("wicket://mover?item=work"))
  model.store.bind(try Shortcut("ctrl+option+w"), to: stock)

  try Data(userLayout.utf8).write(to: folder.appending(path: "user.json"))
  await model.extensions.reload()
  let binding = try #require(model.configuration.hotkeys.first)
  #expect(binding.target == stock)
  model.press(binding.target)
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["stock-layout"])
  await model.finish()
}

@MainActor @Test func aProgramRowSharingAUserItemIDNeedsTheSamePrimaryActionToOfferAHotkey() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "agenda",
    script: #"""
      echo '{"items":[
        {"id":"today","title":"From the program","actions":[{"type":"copy","text":"program"}]},
        {"id":"tomorrow","title":"From both","actions":[{"type":"copy","text":"same","title":"Copy from view"}]}
      ]}'
      """#,
    fields: [
      "items": [["id": "tomorrow", "title": "Stock", "actions": [["type": "copy", "text": "stock"]]]]
    ])
  try Data(
    #"""
    {"items":[
      {"id":"today","title":"Today","actions":[{"type":"copy","text":"user"}]},
      {"id":"tomorrow","title":"Tomorrow","actions":[{"type":"copy","text":"same"}]}
    ]}
    """#.utf8
  ).write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()

  let id = "extension:agenda"
  model.navigator.go(Address(id: id))
  await model.navigator.settled()
  let today = try #require(model.navigator.results.first { $0.row.id == "today" })
  model.navigator.select(today.id)
  #expect(model.navigator.returnAction == .copy("program"))
  model.navigator.toggleActions()
  #expect(model.navigator.results.flatMap(\.row.actions) == [.copy("program")])
  model.navigator.toggleActions()

  let tomorrow = try #require(model.navigator.results.first { $0.row.id == "tomorrow" })
  #expect(
    model.navigator.hotkeyTarget(of: tomorrow) == HotkeyTarget(target: id, item: "tomorrow", isUserItem: true)
  )
  await model.finish()
}

@MainActor @Test func upgradedUnitsReadsUserItemsFromItsRetiredFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
  let units = extensions.appending(path: "units")
  try FileManager.default.copyItem(at: fixtureURL("retired-units"), to: units)
  try Data(
    #"""
    {"items":[{"id":"marathon","title":"Marathon distance","actions":[{"type":"run","input":"42.195 km to mi"}]}]}
    """#.utf8
  ).write(to: units.appending(path: "user.json"))
  #expect(ExtensionHost.isRetired(units))
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  await model.extensions.reload()

  let command = try #require(model.extensions.commands["extension:units"])
  #expect(model.extensions.isBundled(command))
  #expect(command.manifest.command == ["./main"])
  #expect(model.extensions.problems.isEmpty)
  model.navigator.input = "Marathon distance"
  await model.navigator.settled()
  #expect(model.navigator.results.contains { $0.provider == command.id && $0.row.id == "user-item:marathon" })
  await model.finish()
}
