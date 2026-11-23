import Foundation
import Testing

@testable import WicketApp

private func links(in root: URL) throws -> URL {
  let folder = root.appending(path: "extensions/links")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try Data(
    #"""
    {"name":"Links","icon":"link","fields":[{"name":"query","type":"text","description":"Filter bookmarks"}],"items":[
      {"id":"stock","title":"Stock bookmark","actions":[{"type":"copy","text":"stock"}]}
    ]}
    """#.utf8
  ).write(to: folder.appending(path: "wicket.json"))
  return folder.appending(path: "user.json")
}

private let savedBookmark =
  #"{"items":[{"id":"saved","title":"Saved bookmark","actions":[{"type":"copy","text":"saved"}]}]}"#

@MainActor @Test func userItemsJoinManifestItemsAtTheRootAndInTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(savedBookmark.utf8).write(to: links(in: root))
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()

  let id = "extension:links"
  let target = HotkeyTarget(target: id, item: "saved")
  let setHotkey = RowAction(.hotkey(target, record: true))
  model.navigator.input = "bookmark"
  await model.navigator.settled()
  let rootRows = model.navigator.results.filter { $0.provider == id }
  #expect(Set(rootRows.map(\.row.id)) == ["item:stock", "item:saved"])
  let saved = try #require(rootRows.first { $0.row.id == "item:saved" })
  #expect(saved.row.icon == "link" && saved.row.subtitle == "Links")
  model.navigator.toggleActions(saved)
  #expect(model.navigator.results.contains { $0.row.actions == [setHotkey] })
  model.navigator.toggleActions()

  model.navigator.go(Address(id: id))
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.id) == ["stock", "saved"])
  model.navigator.input = "saved"
  await model.navigator.settled()
  let inside = try #require(model.navigator.results.first)
  #expect(model.navigator.results.map(\.row.id) == ["saved"])
  #expect(model.navigator.actions(of: inside) == [.copy("saved"), setHotkey])
  await model.finish()
}

@MainActor @Test func aUserItemHotkeySubmitsItsActionWithoutShowingThePanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(root, name: "mover", script: "cat >> log.jsonl")
  try Data(
    #"""
    {"items":[{"id":"layout","title":"My layout","actions":[{"type":"run","action":"arrange","hidden":true}]}]}
    """#.utf8
  ).write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  await model.extensions.reload()

  model.navigator.input = "My layout"
  await model.navigator.settled()
  #expect(model.navigator.results.contains { $0.row.id == "item:layout" })
  #expect(try requests(in: folder).isEmpty)
  model.press(try #require(HotkeyTarget("wicket://mover?item=layout")))
  await model.navigator.settled()
  let calls = try requests(in: folder)
  #expect(calls.count == 1 && calls.first?.submitted == true && calls.first?.action == "arrange")
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
  try Data(savedBookmark.utf8).write(to: userFile, options: .atomic)
  #expect(
    await eventually(within: .seconds(3)) { model.navigator.results.contains { $0.row.id == "item:saved" } })

  model.navigator.go(Address(id: "extension:links"))
  try Data(savedBookmark.replacingOccurrences(of: "Saved bookmark", with: "New bookmark").utf8)
    .write(to: userFile, options: .atomic)
  #expect(await eventually(within: .seconds(3)) { model.navigator.results.last?.row.title == "New bookmark" })
  try FileManager.default.removeItem(at: userFile)
  #expect(await eventually(within: .seconds(3)) { model.navigator.results.map(\.row.id) == ["stock"] })
  #expect(model.extensions.problems.isEmpty)
  await model.finish()
}

@MainActor @Test(arguments: ["stock", "saved", ""])
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

  model.navigator.go(Address(id: "extension:links"))
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.id) == ["stock"])
  #expect(model.navigator.results.first?.row.actions == [.copy("stock")])
  #expect(
    model.extensions.problems["extension:links"]?.contains(
      "Item ids must be nonempty and unique across wicket.json and user.json") == true)
  await model.finish()
}

@MainActor @Test func aManifestUpdatePausesTheHotkeyForACollidingUserItem() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let script = "cat >> log.jsonl"
  let folder = try extensionFolder(root, name: "mover", script: script)
  try Data(
    #"""
    {"items":[{"id":"work","title":"My layout","actions":[{"type":"run","action":"my-layout","hidden":true}]}]}
    """#.utf8
  ).write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  await model.extensions.reload()

  let target = HotkeyTarget(target: "extension:mover", item: "work")
  model.store.bind(try Shortcut("ctrl+option+w"), to: target)
  #expect(model.configuration.hotkeys.map(\.target) == [target])
  model.press(target)
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["my-layout"])
  #expect(surface.shows == 0)

  _ = try extensionFolder(
    root, name: "mover", script: script,
    fields: [
      "items": [
        [
          "id": "work", "title": "Stock layout",
          "actions": [["type": "run", "action": "stock-layout", "hidden": true]],
        ]
      ]
    ])
  await model.extensions.reload()
  model.press(target)
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["my-layout"])
  #expect(surface.shows == 1)
  let repair = try #require(model.navigator.results.first { $0.row.id == "discovery-error" })
  #expect(repair.row.subtitle == "Hotkeys paused for duplicate item IDs")

  model.navigator.input = "Stock layout"
  await model.navigator.settled()
  let stock = try #require(model.navigator.results.first { $0.row.id == "item:work" })
  #expect(model.navigator.hotkeyTarget(of: stock) == nil)
  model.navigator.select(stock.id)
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(try requests(in: folder).map(\.action) == ["my-layout", "stock-layout"])
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
      """#)
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
  #expect(model.navigator.hotkeyTarget(of: tomorrow) == HotkeyTarget(target: id, item: "tomorrow"))
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
  #expect(model.navigator.results.contains { $0.provider == command.id && $0.row.id == "item:marathon" })
  await model.finish()
}
