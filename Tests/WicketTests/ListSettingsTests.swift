import Foundation
import Testing

@testable import WicketApp

private let linksID = "extension:links-search"

@Test func aListUsesTypedFieldsAndSubstitutesEachStringOnce() throws {
  let data = Data(
    #"""
    {"name":"Example","settings":[{"name":"saved","type":"list","description":"Saved",
      "fields":[{"name":"name","type":"text","description":"Name","multiline":true},
                {"name":"count","type":"number","description":"Count"},
                {"name":"enabled","type":"bool","description":"Enabled"},
                {"name":"kind","type":"choice","description":"Kind","options":["a","b"]},
                {"name":"keyword","type":"text","description":"Keyword","optional":true}],
      "item":{"id":"ignored","title":"{name}","keywords":["a","{keyword}"],
        "actions":[{"type":"run","extension":"example","fields":{"body":"{name}: {count} / {query}"}}]}
    }]}
    """#.utf8)
  let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
  let list = try #require(manifest.settings.first?.list)
  let name = "Name with {count}, quotes \"and\"\nnewlines"
  let values = ["id": "my-item", "name": name, "count": "5", "enabled": "false", "kind": "a"]
  #expect(list.accepts(values))
  for (field, value) in [("name", ""), ("count", "five"), ("enabled", "TRUE"), ("kind", "c")] {
    #expect(!list.accepts(values.merging([field: value]) { _, replacement in replacement }))
  }
  let row = try #require(list.row(values))
  #expect(row.id == "my-item" && row.entryList == "saved")
  #expect(row.title == name && row.keywords == ["a"])
  #expect(row.actions == [.run(Address(extensionName: "example", fields: ["body": name + ": 5 / {query}"]))])
  for (from, to) in [
    (#""name":"name""#, #""name":"id""#),
    (#""type":"number""#, #""type":"list""#),
    (#""type":"number""#, #""type":"number","multiline":true"#),
    (#""name":"keyword""#, #""name":"count""#),
    (#""type":"run""#, #""type":"typo""#),
  ] {
    let invalid = try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: from, with: to)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ExtensionManifest.self, from: Data(invalid.utf8))
    }
  }
}

@MainActor @Test func listSettingsIsolateMalformedDataAndPublishValidEntriesWithoutRunningAProgram()
  async throws
{
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let records: [String: Any] = [
    "name": "records", "type": "list", "description": "Records",
    "fields": [["name": "title", "type": "text", "description": "Title"]],
    "item": ["title": "{title}", "actions": [["type": "copy", "text": "{title}"]]],
  ]
  let folder = try extensionFolder(
    root, name: "echo", script: "cat >> log.jsonl; echo '{\"items\":[]}'",
    fields: ["settings": [records]])
  _ = try extensionFolder(root, name: "broken", fields: ["settings": [records]])
  _ = try extensionFolder(root, name: "malformed", fields: ["settings": [records]])
  let model = LauncherModel.testing(in: root, bundled: nil)
  try Data(
    #"""
    {"textSize":"small","extensions":{
      "echo":{"records":[{"id":"valid","title":"Entry Title"},17,{"id":"valid","title":"Duplicate"}]},
      "broken":{"records":"bad"},"malformed":false}}
    """#.utf8
  ).write(to: model.store.url)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(model.store.problem == nil && model.configuration.textSize == .small)
  #expect(model.extensions.problems["extension:echo"]?.settings?.contains("entry 2") == true)
  #expect(model.extensions.problems["extension:broken"]?.settings?.contains("must be an array") == true)
  #expect(model.extensions.problems["extension:malformed"]?.settings?.contains("must be an object") == true)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.input = "Entry Title"
  await navigator.settled()
  let row = try #require(navigator.results.first)
  let target = HotkeyTarget(target: "extension:echo", item: "valid", entryList: "records")
  #expect(row.row.id == "entry:records/valid")
  #expect(navigator.hotkeyTarget(of: row) == target)
  #expect(try requests(in: folder).isEmpty)

  navigator.toggleActions(row)
  let edit = try #require(navigator.results.first { $0.row.title == "Edit in Settings…" })
  navigator.run(edit.row.actions.first)
  #expect(surface.effects.last == .settingsList(.init(folder: "echo", setting: "records")))

  let command = try #require(model.extensions.commands["extension:echo"])
  _ = try await model.extensions.view(command, request: ProviderRequest(input: ""))
  #expect(
    try requests(in: folder).first?.settings["records"]
      == .array([
        .object(["id": .string("valid"), "title": .string("Entry Title")])
      ]))
  await model.finish()
}

@MainActor @Test func deletingAnEntryRemovesItsBindingAndTrashingAnExtensionKeepsItsLists() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try extensionFolder(
    root, name: "local",
    fields: [
      "settings": [
        [
          "name": "saved", "type": "list", "description": "Saved",
          "fields": [["name": "title", "type": "text", "description": "Title"]],
          "item": ["title": "{title}", "actions": [["type": "copy", "text": "{title}"]]],
        ]
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  await model.extensions.reload()
  let list = try #require(model.extensions.commands["extension:local"]?.manifest.settings.first?.list)
  let entry = HotkeyTarget(target: "extension:local", item: "one", entryList: "saved")
  let other = HotkeyTarget(target: "extension:local", item: "two", entryList: "saved")
  #expect(
    model.store.change {
      try $0.set(
        "local", to: ["saved": [["id": "one", "title": "One"], ["id": "two", "title": "Two"]]],
        in: "extensions")
    })
  model.store.bind(try Shortcut("ctrl+option+1"), to: entry)
  model.store.bind(try Shortcut("ctrl+option+2"), to: other)
  #expect(model.store.change { try $0.changeEntry(in: list, folder: "local", id: "one", values: nil) })
  #expect(model.configuration.hotkeys.map(\.target) == [other])
  #expect(model.extensions.commands["extension:local"]?.item(for: entry) == nil)
  try FileManager.default.createDirectory(
    at: root.appending(path: "trash"), withIntermediateDirectories: true)
  model.extensions.moveToTrash = {
    try FileManager.default.moveItem(at: $0, to: root.appending(path: "trash/local"))
  }
  try model.extensions.trash("extension:local")
  #expect(model.store.change { try $0.forget(extension: "local") })
  await model.extensions.reload()
  #expect(
    model.extensions.commands["extension:local"] == nil
      && !FileManager.default.fileExists(atPath: folder.path))
  #expect(model.configuration.extensions["local"]?["saved"].array.first?["id"].string == "two")
  #expect(model.configuration.hotkeys.isEmpty)
  await model.finish()
}

@MainActor @Test func migrationRewritesThreeKindsOfHotkeysInOneWriteAndNeverReadsTheFileAgain() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let local = root.appending(path: "extensions/links-search")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  let source = local.appending(path: "user.json")
  let original = Data(
    #"""
    {"items":[
      {"id":"docs","title":"Docs","url":"https://example.com/"},
      {"id":"search","title":"Search","url":"https://example.com/?q={query}","keyword":"eg"},
      {"id":"fixed","title":"Fixed","actions":[{"type":"run","action":"open-link","hidden":true,
        "fields":{"query":"fixed","template":"https://example.com/?q={query}","bundleID":"example.browser"}}]}
    ]}
    """#.utf8)
  try original.write(to: source)

  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  try Data(
    #"""
    {"future":true,"providers":[{"id":"extension:links-search","enabled":false}],"hotkeys":[
      {"keys":"ctrl+option+1","address":"wicket://links-search?user-item=docs"},
      {"keys":"ctrl+option+2","address":"wicket://links-search?user-item=search","future":"keep"},
      {"keys":"ctrl+option+3","address":"wicket://links-search?user-item=fixed"}]}
    """#.utf8
  ).write(to: model.store.url)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(try Data(contentsOf: source) == original)
  #expect(
    model.configuration.hotkeys.map { $0.target.description } == [
      "wicket://links-search?entry=links/docs", "wicket://links-search?entry=searches/search",
      "wicket://my-items?item=fixed",
    ])
  #expect(!model.configuration.isEnabled("extension:my-items", extensions: model.extensions.ids))
  let destination = try #require(model.extensions.commands["extension:my-items"]?.items.first?.actions.first)
  guard case .run(let address) = destination.kind else {
    Issue.record("Expected a migrated run")
    return
  }
  #expect(address.targetID == linksID && address.fields?["query"] == "fixed")
  #expect(address.fields?["bundleID"] == "example.browser")
  let saved = try Data(contentsOf: model.store.url)
  let json = try JSONDecoder().decode(JSONValue.self, from: saved)
  #expect(json["future"].bool && json["hotkeys"].array[1]["future"].string == "keep")
  #expect(model.navigator.results.first?.row.title == "Moved 3 saved items")
  await model.finish()

  try Data("The old file is unreadable now".utf8).write(to: source)
  let relaunch = LauncherModel.testing(in: root, bundled: bundledExtensions)
  relaunch.store.start(watching: false)
  await relaunch.extensions.reload()
  #expect(try Data(contentsOf: relaunch.store.url) == saved)
  #expect(relaunch.extensions.problems[linksID] == nil)
  #expect(relaunch.navigator.results.first?.row.title != "Moved 3 saved items")
  #expect(relaunch.extensions.commands[linksID]?.items.count == 2)
  await relaunch.finish()
}

@MainActor @Test func saveActionsPrefillOnlyAListOwnedByTheSubmittingProgram() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let response = #"{"items":[],"actions":[{"type":"save","setting":"moves","values":{"title":"Captured"}}]}"#
  let list =
    [
      "name": "moves", "type": "list", "description": "Moves", "editable": false,
      "fields": [["name": "title", "type": "text", "description": "Title"]],
    ] as [String: Any]
  _ = try extensionFolder(
    root, name: "owner", script: "echo '\(response)'", fields: ["settings": [list]])
  _ = try extensionFolder(root, name: "other", script: "echo '\(response)'")
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.runHidden(Address(extensionName: "owner", action: "capture"), from: nil)
  await model.navigator.settled()
  #expect(
    surface.effects.last
      == .settingsList(.init(folder: "owner", setting: "moves", values: ["title": "Captured"])))
  #expect(model.configuration.extensions["owner"] == nil)

  let effects = surface.effects
  model.navigator.runHidden(Address(extensionName: "other", action: "capture"), from: nil)
  await model.navigator.settled()
  #expect(surface.effects == effects)
  #expect(model.navigator.actionProblem?.contains("its own extension") == true)
  let foreign = response.replacingOccurrences(of: #""setting""#, with: #""extension":"owner","setting""#)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ProviderView.self, from: Data(foreign.utf8))
  }
  await model.finish()
}

@MainActor @Test func quicklinksEmptyRowOpensTheBookmarksList() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  await model.extensions.reload()
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.go(Address(id: linksID, link: true))
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Add a Quicklink…"])
  model.navigator.run()
  #expect(surface.effects.last == .settingsList(.init(folder: "links-search", setting: "links")))
  await model.finish()
}
