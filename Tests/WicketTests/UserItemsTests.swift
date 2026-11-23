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
