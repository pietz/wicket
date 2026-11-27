import Foundation
import Testing

@testable import WicketApp

private let linksID = "extension:links-search"

@Test func listFieldDefaultsPrefillOnlyNewEntriesAndYieldToSuppliedValues() throws {
  let data = Data(
    #"""
    {"name":"Example","contract":2,"command":["./main"],"settings":[{"name":"saved","type":"list","description":"Saved","fields":[
      {"name":"width","type":"number","description":"Width","min":10,"max":100,"default":50},
      {"name":"enabled","type":"bool","description":"Enabled"},
      {"name":"kind","type":"choice","description":"Kind","options":["a","b"],"default":"b","optional":true},
      {"name":"source","type":"text","description":"Source","hidden":true,"default":"settings"}]}]}
    """#.utf8)
  let list = try #require(JSONDecoder().decode(ExtensionManifest.self, from: data).settings.first?.list)
  let add = SettingsEntryDraft(folder: "example", list: list)
  #expect(add.initialValues == ["width": "50", "enabled": "false", "kind": "b", "source": "settings"])
  #expect(list.addable && list.missingHidden([:]).isEmpty)
  #expect(list.missingHidden(["source": ""]) == ["source"])
  #expect(!list.accepts([:]) && list.accepts(add.initialValues))
  let capture = SettingsEntryDraft(folder: "example", list: list, values: ["width": "33.33"])
  #expect(capture.initialValues["width"] == "33.33")
  #expect(capture.initialValues["kind"] == "b")
  let existing = ["id": "example", "width": "60", "enabled": "true", "source": "import"]
  let edit = SettingsEntryDraft(folder: "example", list: list, values: existing, entryID: "example")
  #expect(edit.initialValues == existing)
  let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(
    of: "\"default\":50", with: "\"default\":5")
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(invalid.utf8))
  }
}

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

@MainActor @Test func deletingAnEntryRemovesItsBindingButTrashingTheExtensionKeepsSettings() async throws {
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
  #expect(model.store.change { try $0.setProvider("extension:local", enabled: false) })
  let saved = try Data(contentsOf: model.store.url)
  let pane = SettingsPane(
    section: 3, store: model.store, extensions: model.extensions,
    clipboard: ClipboardHistory(
      url: root.appending(path: "clipboard.json"), pasteboard: FakePasteboard(), interval: nil),
    runs: AgentHistory(url: root.appending(path: "history.json")), updater: nil, pauseHotkey: { _ in })
  try FileManager.default.createDirectory(
    at: root.appending(path: "trash"), withIntermediateDirectories: true)
  model.extensions.moveToTrash = {
    try FileManager.default.moveItem(at: $0, to: root.appending(path: "trash/local"))
  }
  try pane.trashExtension(
    "extension:local", confirmed: model.extensions.locations["extension:local"]?.localCopy)
  await model.extensions.reload()
  #expect(
    model.extensions.commands["extension:local"] == nil
      && !FileManager.default.fileExists(atPath: folder.path))
  #expect(try Data(contentsOf: model.store.url) == saved)
  try FileManager.default.moveItem(at: root.appending(path: "trash/local"), to: folder)
  await model.extensions.reload()
  #expect(model.extensions.commands["extension:local"]?.item(for: other)?.title == "Two")
  #expect(!model.configuration.isEnabled("extension:local", extensions: model.extensions.ids))
  #expect(model.configuration.hotkeys.map(\.target) == [other])
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

@MainActor @Test func aSubmittedSaveResponseTakesPrecedenceOverMatchingSavedEntries() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try extensionFolder(
    root, name: "notes",
    script: #"echo '{"items":[],"actions":[{"type":"save","setting":"notes","values":{"title":"Draft"}}]}'"#,
    fields: [
      "submit": true,
      "settings": [
        [
          "name": "notes", "type": "list", "description": "Notes",
          "fields": [["name": "title", "type": "text", "description": "Title"]],
          "item": ["title": "{title}", "actions": [["type": "copy", "text": "{title}"]]],
        ]
      ],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  #expect(
    model.store.change {
      try $0.set("notes", to: ["notes": [["id": "old", "title": "Draft"]]], in: "extensions")
    })
  await model.extensions.reload()
  let surface = RecordingSurface()
  let nav = model.navigator
  nav.surface = surface
  nav.go(Address(extensionName: "notes", input: "Draft"), submitted: true)
  await nav.settled()
  #expect(
    surface.effects.last
      == .settingsList(.init(folder: "notes", setting: "notes", values: ["title": "Draft"])))
  await model.finish()
}

@MainActor @Test func reopeningQuicklinksWithItsHotkeyRestoresLiveFiltering() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  model.store.start(watching: false)
  #expect(
    model.store.change {
      try $0.set(
        "links-search",
        to: [
          "links": [
            ["id": "docs", "title": "Docs", "url": "https://example.com/docs"],
            ["id": "status", "title": "Status", "url": "https://example.com/status"],
          ],
          "searches": [
            ["id": "site", "title": "Site", "keyword": "site", "url": "https://example.com/?q={query}"]
          ],
        ], in: "extensions")
    })
  await model.extensions.reload()
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  model.press(HotkeyTarget(target: linksID, item: "site", entryList: "searches"))
  await nav.settled()
  #expect(nav.command?.promptedRun != nil)
  model.press(HotkeyTarget(target: linksID))
  await nav.settled()
  #expect(nav.results.contains { $0.row.title == "Status" })
  nav.editInput("Docs")
  await nav.settled()
  #expect(nav.results.filter { $0.row.entryList == "links" }.map(\.row.title) == ["Docs"])
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

@MainActor @Test func listFreeMigrationPublishesOnlyAfterConfigReplacementAndRetriesInSession() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let legacy = try extensionFolder(root, name: "custom")
  let source = legacy.appending(path: "user.json")
  try Data(#"{"items":[{"id":"one","title":"Legacy item","actions":[{"type":"run","action":"one"}]}]}"#.utf8)
    .write(to: source)
  let configFolder = root.appending(path: "config-files")
  let files = FileManager.default
  try files.createDirectory(at: configFolder, withIntermediateDirectories: true)
  let configuration = configFolder.appending(path: "config.json")
  let original = Data(
    #"""
    {"providers":[{"id":"extension:custom","enabled":false}],
     "hotkeys":[{"keys":"ctrl+option+1","address":"wicket://custom?user-item=one"}]}
    """#.utf8)
  try original.write(to: configuration)
  // An existing lock remains writable while the directory refuses the atomic replacement.
  try Data().write(to: configFolder.appending(path: ".config.json.lock"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  try files.createSymbolicLink(at: model.store.url, withDestinationURL: configuration)
  model.store.start(watching: false)
  try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configFolder.path)
  defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configFolder.path) }

  await model.extensions.reload()
  let extensions = root.appending(path: "extensions")
  let staged = extensions.appending(path: ".wicket-migration")
  #expect(files.fileExists(atPath: staged.path))
  #expect(try files.contentsOfDirectory(atPath: staged.path).isEmpty)
  #expect(model.extensions.problems["extension:custom"]?.settings?.contains("Couldn’t migrate") == true)
  #expect(try Data(contentsOf: configuration) == original)
  await model.extensions.reload()
  #expect(model.extensions.commands["extension:my-items"] == nil)
  #expect(!files.fileExists(atPath: extensions.appending(path: "my-items").path))

  try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configFolder.path)
  model.store.load()
  #expect(await eventually { model.extensions.commands["extension:my-items"] != nil })
  #expect(model.extensions.problems["extension:custom"] == nil)
  let target = try #require(HotkeyTarget("wicket://my-items?item=one"))
  #expect(model.configuration.hotkeys.first?.target == target)
  #expect(!model.configuration.isEnabled("extension:my-items", extensions: model.extensions.ids))
  let item = try #require(model.extensions.commands["extension:my-items"]?.item(for: target))
  #expect(item.actions == [.run(Address(extensionName: "custom", action: "one"))])
  #expect(model.configuration.pendingPersonalItems.isEmpty)
  #expect(model.configuration.migratedPersonalItems.contains("custom"))
  #expect(files.fileExists(atPath: source.path))
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func pendingMigrationResumesAtTheRecordedDestination(published: Bool) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let staging = UUID()
  let model = LauncherModel.testing(in: root, bundled: nil)
  let destination = root.appending(path: "extensions/my-items")
  let staged = root.appending(path: "extensions/.wicket-migration/\(staging.uuidString)")
  let manifest = Data(
    #"""
    {"name":"My Items","items":[{"id":"one","title":"Edited item","actions":[{"type":"copy","text":"text"}]}]}
    """#.utf8)
  let folder = published ? destination : staged
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try manifest.write(to: folder.appending(path: "wicket.json"))
  var config = Configuration()
  config.hotkeys = [
    .init(keys: try Shortcut("ctrl+option+1"), target: .init(target: "extension:my-items", item: "one"))
  ]
  config.pendingPersonalItems["old"] = .init(destination: "my-items", staging: staging, count: 1)
  try config.save(at: model.store.url)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(model.configuration.pendingPersonalItems.isEmpty)
  #expect(model.configuration.migratedPersonalItems == ["old"])
  #expect(model.extensions.commands["extension:my-items"]?.items.first?.title == "Edited item")
  #expect(model.extensions.commands["extension:my-items-2"] == nil)
  #expect(try Data(contentsOf: destination.appending(path: "wicket.json")) == manifest)
  await model.finish()
}

@MainActor @Test func repairingALegacyFileRetriesMigrationThroughTheExtensionWatcher() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let legacy = try extensionFolder(root, name: "custom")
  let source = legacy.appending(path: "user.json")
  try Data("{".utf8).write(to: source)
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.start(watching: false)
  model.extensions.start()
  await model.extensions.firstScan()
  #expect(model.extensions.problems["extension:custom"]?.settings != nil)

  try Data(#"{"items":[{"id":"one","title":"Legacy item","actions":[{"type":"copy","text":"item"}]}]}"#.utf8)
    .write(to: source, options: .atomic)
  #expect(await eventually { model.extensions.commands["extension:my-items"] != nil })
  #expect(model.extensions.problems["extension:custom"] == nil)
  await model.finish()
}

@MainActor @Test func anOldQuicklinksOverrideMigratesShortLinksToMyItems() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try extensionFolder(root, name: "links-search")
  try Data(
    #"{"items":[{"id":"old","title":"Old Bookmark","url":"https://example.org/","keyword":"old"}]}"#.utf8
  )
  .write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(model.extensions.commands[linksID]?.manifest.settings.isEmpty == true)
  let item = try #require(model.extensions.commands["extension:my-items"]?.items.first)
  #expect(item.keywords == ["old"] && item.actions == [.open(URL(string: "https://example.org/")!)])
  await model.finish()
}

@MainActor @Test func entrySavesMergeWithAgentEditsAndValidateTheExpandedBookmarkURL() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  model.store.start(watching: false)
  await model.extensions.reload()
  let list = try #require(model.extensions.commands[linksID]?.manifest.settings.first?.list)
  #expect(list.entryName == "Bookmark")
  let file = ConfigurationFile(url: model.store.url)
  let original = ["id": "docs", "title": "Original", "url": "https://example.com/", "keyword": "docs"]
  try file.changeEntry(in: list, folder: "links-search", id: "docs", values: original, inserting: true)

  var saved = original
  saved["title"] = "Agent Title"
  saved["url"] = "https://example.org/"
  saved["future"] = "preserve"
  try file.set("links-search", to: ["links": [saved]], in: "extensions")
  var edited = original
  edited["title"] = "User Title"
  edited["keyword"] = nil
  try file.changeEntry(in: list, folder: "links-search", id: "docs", values: edited, original: original)
  let config = try Configuration.load(at: file.url)
  let value = try #require(config.extensions["links-search"]?["links"].array.first)
  #expect(value["title"].string == "User Title")
  #expect(value["url"].string == "https://example.org/")
  #expect(value["future"].string == "preserve" && value["keyword"] == .null)

  for url in ["example.com", "https:///path", "https://", "https://example.com/a b"] {
    let bad = ["id": "bad", "title": "Bad", "url": url]
    #expect(list.urlProblem(bad) != nil && list.row(bad) == nil)
    #expect(throws: ExtensionFailure.self) {
      try file.changeEntry(in: list, folder: "links-search", id: "bad", values: bad, inserting: true)
    }
  }
  for url in ["https://example.com/", "mailto:hi@example.com", "custom:bookmark", "wicket://settings"] {
    let good = ["id": "good", "title": "Good", "url": url]
    #expect(list.urlProblem(good) == nil && list.row(good) != nil)
  }
  let bad = ["id": "relative", "title": "Relative", "url": "example.com"]
  try file.set("links-search", to: ["links": [bad]], in: "extensions")
  model.store.load()
  #expect(model.extensions.commands[linksID]?.items.isEmpty == true)
  #expect(model.extensions.problems[linksID]?.settings != nil)
  await model.finish()
}

@MainActor @Test func savedWindowMovesMigrateInPlaceWithoutChangingTheirBindings() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let file = ConfigurationFile(url: root.appending(path: "config.json"))
  let target = try #require(HotkeyTarget("wicket://window?entry=moves/legacy"))
  let shortcut = try Shortcut("ctrl+option+1")
  let legacy = [
    "id": "legacy", "title": "Coding", "keyword": "code", "future": "kept",
    "definition":
      #"{"kind":"move","placement":{"display":"12345678-1234-4321-1234-ABCDEFABCDEF","fallback":"current","rect":[0.01,0.17,0.3333,0.8],"gap":0}}"#,
  ]
  let tiny = [
    "id": "tiny", "title": "Tiny",
    "definition": #"{"kind":"move","placement":{"display":"current","rect":[0,0,0.04,0.08]}}"#,
  ]
  var malformed = legacy
  malformed["id"] = "malformed"
  malformed["definition"] = #"{"kind":"layout"}"#
  try Configuration().save(at: file.url)
  try file.bind(shortcut, to: target)
  try file.set("window", to: ["moves": [legacy, tiny, malformed, codingMove], "gap": "8"], in: "extensions")
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  model.store.start(watching: false)
  await model.extensions.reload()

  let saved = try Configuration.load(at: file.url)
  #expect(saved.hotkeys == [.init(keys: shortcut, target: target)])
  #expect(saved.extensions["window"]?["gap"].string == "8")
  let entries = saved.extensions["window"]?["moves"].array ?? []
  let expected = [
    "id": "legacy", "title": "Coding", "keyword": "code", "future": "kept",
    "anchor": "bottom-left", "width": "33.33", "height": "80",
  ]
  #expect(
    entries
      == [
        expected, ["id": "tiny", "title": "Tiny", "anchor": "top-left", "width": "10", "height": "10"],
        malformed, codingMove,
      ].map { .object($0.mapValues(JSONValue.string)) })
  let item = model.extensions.commands["extension:window"]?.item(for: target)
  #expect(item?.title == "Coding" && item?.keywords == ["code"])
  #expect(
    item?.actions.first?.kind
      == .run(
        Address(
          fields: ["anchor": "bottom-left", "width": "33.33", "height": "80"], action: "apply-placement",
          hidden: true)))
  #expect(model.extensions.problems["extension:window"]?.settings?.contains("moves entry 3") == true)

  let disk = try Data(contentsOf: file.url)
  await model.extensions.reload()
  #expect(try Data(contentsOf: file.url) == disk)

  malformed["definition"] = legacy["definition"]
  try file.set("window", to: ["moves": [expected, malformed, codingMove], "gap": "8"], in: "extensions")
  model.store.load()
  let repaired = try #require(HotkeyTarget("wicket://window?entry=moves/malformed"))
  #expect(
    await eventually(within: .seconds(3)) {
      model.extensions.commands["extension:window"]?.item(for: repaired) != nil
    })
  #expect(model.configuration.extensions["window"]?["moves"].array[1]["definition"].string == nil)
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func anOlderLocalWindowsExtensionKeepsItsOwnMoveSchema(disconnected: Bool) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let list: [String: Any] = [
    "name": "moves", "type": "list", "description": "Saved Moves",
    "fields": [
      ["name": "title", "type": "text", "description": "Title"],
      ["name": "definition", "type": "text", "description": "Definition", "hidden": true],
    ],
    "item": ["title": "{title}", "actions": [["type": "run", "action": "apply-definition"]]],
  ]
  let local = try extensionFolder(root, name: "window", script: "echo '{}'", fields: ["settings": [list]])
  let file = ConfigurationFile(url: root.appending(path: "config.json"))
  try Configuration().save(at: file.url)
  let legacy = [
    "id": "legacy", "title": "Coding",
    "definition": #"{"kind":"move","placement":{"display":"current","rect":[0,0,0.5,1]}}"#,
  ]
  try file.set("window", to: ["moves": [legacy]], in: "extensions")
  let disk = try Data(contentsOf: file.url)
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(try Data(contentsOf: file.url) == disk)
  #expect(model.extensions.commands["extension:window"]?.items.first?.id == "legacy")
  #expect(model.extensions.problems["extension:window"]?.settings == nil)
  let manifest = local.appending(path: "wicket.json")
  let data = try Data(contentsOf: manifest)
  let backup = root.appending(path: "backup")
  let remote = root.appending(path: "remote")
  if disconnected {
    try FileManager.default.moveItem(at: local, to: backup)
    try FileManager.default.createSymbolicLink(at: local, withDestinationURL: remote)
  } else {
    try Data("{".utf8).write(to: manifest, options: .atomic)
  }
  await model.extensions.reload()
  #expect(model.extensions.commands["extension:window"]?.manifest.name == "Windows")
  #expect(try Data(contentsOf: file.url) == disk)
  if disconnected {
    try FileManager.default.moveItem(at: backup, to: remote)
  } else {
    try data.write(to: manifest, options: .atomic)
  }
  await model.extensions.reload()
  #expect(try Data(contentsOf: file.url) == disk)
  #expect(model.extensions.commands["extension:window"]?.items.first?.id == "legacy")
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func quicklinkMigrationRequiresAnEquivalentLauncherItem(hasDifferentAction: Bool) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  var links: [String: Any] = [
    "name": "links", "type": "list", "description": "Bookmarks",
    "fields": [
      ["name": "title", "type": "text", "description": "Title"],
      ["name": "url", "type": "text", "description": "URL"],
    ],
  ]
  if hasDifferentAction {
    links["item"] = ["title": "{title}", "actions": [["type": "copy", "text": "{url}"]]]
  }
  let folder = try extensionFolder(root, name: "links-search", fields: ["settings": [links]])
  try Data(#"{"items":[{"id":"old","title":"Old Bookmark","url":"https://example.org/"}]}"#.utf8)
    .write(to: folder.appending(path: "user.json"))
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  try Data(#"{"hotkeys":[{"keys":"ctrl+option+1","address":"wicket://links-search?user-item=old"}]}"#.utf8)
    .write(to: model.store.url)
  model.store.start(watching: false)
  await model.extensions.reload()

  #expect(model.configuration.extensions["links-search"] == nil)
  let target = try #require(HotkeyTarget("wicket://my-items?item=old"))
  #expect(model.configuration.hotkeys.first?.target == target)
  let item = try #require(model.extensions.commands["extension:my-items"]?.item(for: target))
  let url = try #require(URL(string: "https://example.org/"))
  #expect(item.actions == [.open(url)])
  await model.finish()
}

@Test func aRequiredHiddenFieldRulesOutAddingByHandAndMustComeFromSave() throws {
  func list(_ hidden: String) throws -> SettingList {
    let data = Data(
      #"""
      {"name":"Example","command":["./main"],"contract":2,"settings":[{"name":"moves","type":"list","description":"Moves",
        "fields":[{"name":"title","type":"text","description":"Title"},
                  {"name":"definition","type":"text","description":"Definition",\#(hidden)}]}]}
      """#.utf8)
    return try #require(try JSONDecoder().decode(ExtensionManifest.self, from: data).settings.first?.list)
  }
  let required = try list(#""hidden":true"#)
  #expect(!required.addable)
  #expect(required.missingHidden(["title": "Left"]) == ["definition"])
  #expect(required.missingHidden(["title": "Left", "definition": "  "]) == ["definition"])
  #expect(required.missingHidden(["title": "Left", "definition": "{}"]).isEmpty)
  let optional = try list(#""hidden":true,"optional":true"#)
  #expect(optional.addable && optional.missingHidden(["title": "Left"]).isEmpty)
}
