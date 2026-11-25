import Foundation
import Testing

@testable import WicketApp

@Test func choiceOptionsRoundTripTheirAppRequirement() throws {
  let json = Data(#"["System default",{"value":"App","label":"App","requiresApp":"com.example.app"}]"#.utf8)
  let options = try JSONDecoder().decode([Field.Option].self, from: json)
  #expect(options == [.init("System default"), .init("App", requiresApp: "com.example.app")])
  let encoded = try JSONEncoder().encode(options)
  #expect(try JSONDecoder().decode([Field.Option].self, from: encoded) == options)
}

private func manifest(_ json: String) throws -> ExtensionManifest {
  try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
}

@Test func aManifestDeclaresTypedFields() throws {
  let caffeinate = try manifest(
    #"{"contract":2,"name":"Caffeinate","command":["./main.py"],"fields":[{"name":"hours","type":"number","description":"Hours","placeholder":"hours"},{"name":"minutes","type":"number","description":"Minutes"}],"submit":true}"#
  )
  #expect(caffeinate.submit && caffeinate.fields.map(\.name) == ["hours", "minutes"])
  #expect(caffeinate.fields.map(\.placeholder) == ["hours", nil])
  let plain = try manifest(#"{"contract":2,"name":"Plain","command":["./main.py"]}"#)
  #expect(!plain.submit && plain.fields.isEmpty)
  for invalid in [
    #"{"contract":2,"name":"A","command":["x"],"fields":[{"name":"","type":"text","description":"Empty name"}]}"#,
    #"{"contract":2,"name":"A","command":["x"],"fields":[{"name":"a","type":"text","description":"A"},{"name":"a","type":"text","description":"A"}]}"#,
    #"{"contract":2,"name":"A","command":["x"],"fields":[{"name":"a","type":"text","description":"A"},{"name":"b","type":"text","description":"B"},{"name":"c","type":"text","description":"C"},{"name":"d","type":"text","description":"D"}]}"#,
    #"{"contract":2,"name":"A","command":["x"],"fields":["a"]}"#,
    #"{"contract":2,"name":"A","command":["x"],"submit":"yes"}"#,
    #"{"name":"A","items":[],"submit":true}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"choice","description":"A"}]}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"choice","description":"A","options":["x","x"]}]}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"widget","description":"A"}]}"#,
    #"{"contract":2,"name":"A","command":["x"],"arguments":["a"]}"#,
  ] {
    #expect(throws: (any Error).self, Comment(rawValue: invalid)) { try manifest(invalid) }
  }
}

@Test func searchArgumentsAndListEntriesUseTheSameChoiceAndNumberRules() throws {
  let fields = """
    [
      {"name":"scale","type":"choice","description":"Scale","options":["plain",{"value":"log","label":"Logarithmic"}]},
      {"name":"size","type":"number","description":"Size","min":0.5,"max":2,"step":0.25}
    ]
    """
  let command = try manifest(
    """
    {"contract":2,"name":"Chart","command":["./chart"],"fields":\(fields),
     "settings":[{"name":"presets","description":"Presets","type":"list","fields":\(fields)}]}
    """)
  let list = try #require(command.settings.first?.list)
  #expect(list.fields == command.fields)
  #expect(list.fields[0].options == [.init("plain"), .init("log", label: "Logarithmic")])
  #expect(list.accepts(["scale": "log", "size": "1.250"]))
  #expect(!list.accepts(["scale": "Logarithmic", "size": "1.25"]))
  #expect(!list.accepts(["scale": "plain", "size": "1.2"]))
  #expect(!list.accepts(["scale": "log", "size": "2.25"]))
  #expect(command.fields[1].canonical("1.250") == "1.25")
  let roundTrip = try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(command))
  #expect(roundTrip == command)
}

/// A logging extension: every request is appended to `log.jsonl`, and the view lists one item that
/// runs with a field value.
@MainActor private func logging(
  _ root: URL, name: String, fields: [String: Any]
) throws -> (folder: URL, requests: () throws -> [ProviderRequest]) {
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    print(json.dumps({'items':[{'id':'again','title':'Again','actions':[{'type':'run','fields':{'text':'again'}}]},
      {'id':'other','title':'Other','actions':[]}]}))
    """
  var all: [String: Any] = ["name": name, "command": ["/usr/bin/python3", "main.py"]]
  all.merge(fields) { _, value in value }
  let folder = try extensionFolder(root, name: name.lowercased(), fields: all)
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  return (
    folder,
    { try requests(in: folder) }
  )
}

@MainActor @Test func theModelOffersTheSelectedCommandsFieldsAndEntersWithTheirValues() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Caffeinate",
    fields: [
      "fields": [
        ["name": "hours", "type": "number", "description": "Hours", "placeholder": "hours"],
        ["name": "minutes", "type": "number", "description": "Minutes"],
      ]
    ])
  _ = try extensionFolder(root, name: "caffeine", fields: ["fields": []])  // A row without fields.
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  model.navigator.input = "caff"
  await model.navigator.settled()
  // The command row is selected, so its fields are on offer, all unfilled.
  let row = try #require(model.navigator.selected)
  #expect(row.row.id == "command" && row.provider == "extension:caffeinate")
  #expect(
    model.navigator.fieldSlots.map(\.name) == ["hours", "minutes"]
      && model.navigator.fieldValues.isEmpty)
  model.navigator.setField("hours", to: "4")
  model.navigator.setField("minutes", to: "")
  model.navigator.setField("seconds", to: "9")
  #expect(model.navigator.fieldValues == ["hours": "4"])
  #expect(try requests().isEmpty)
  // Another row has none and drops the values; dismissing drops them too.
  let other = try #require(model.navigator.results.first { $0.provider == "extension:caffeine" })
  model.navigator.select(other.id)
  #expect(model.navigator.fieldSlots.isEmpty && model.navigator.fieldValues.isEmpty)
  model.navigator.select(row.id)
  #expect(model.navigator.fieldValues.isEmpty)
  model.navigator.setField("hours", to: "1")
  model.navigator.dismiss()
  model.navigator.input = "caff"
  await model.navigator.settled()
  #expect(model.navigator.selected?.id == row.id && model.navigator.fieldValues.isEmpty)
  // Return enters the command with the filled values as its fields, in a submitted request.
  model.navigator.setField("hours", to: "4")
  model.navigator.setField("minutes", to: "30")
  #expect(
    model.navigator.returnAction
      == .run(Address(id: "extension:caffeinate", input: "", fields: ["hours": "4", "minutes": "30"])))
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.fieldValues == ["hours": "4", "minutes": "30"])
  #expect(try requests().map(\.submitted) == [true])
  #expect(try requests().last?.fields == ["hours": "4", "minutes": "30"])
  // Inside, the same fields are on offer with the command's values; an edit reruns like typing.
  #expect(model.navigator.fieldSlots.map(\.name) == ["hours", "minutes"])
  #expect(model.navigator.fieldValues == ["hours": "4", "minutes": "30"])
  model.navigator.setField("minutes", to: "")
  await model.navigator.settled()
  #expect(model.navigator.fieldValues == ["hours": "4"])
  #expect(try requests().last.map { !$0.submitted && $0.fields == ["hours": "4"] } == true)
  // A run action adds its supplied field values.
  model.navigator.select(try #require(model.navigator.results.first { $0.row.id == "again" }).id)
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.fieldValues == ["hours": "4", "text": "again"])
  await model.finish()
}

@MainActor @Test(arguments: [false, true], [false, true])
func aRootItemUsesItsRunsFields(crossExtension: Bool, byHotkey: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  var run: [String: Any] = [
    "type": "run", "action": "search", "input": "", "fields": ["link": "youtube", "limit": "10"],
    "hidden": crossExtension,
  ]
  if crossExtension { run["extension"] = "search" }
  let item: [String: Any] = ["id": "yt", "title": "Search YouTube", "keywords": ["yt"], "actions": [run]]
  if crossExtension {
    _ = try extensionFolder(
      root, name: "personal", fields: ["command": NSNull(), "fields": [], "items": [item]])
  }
  let folder = try extensionFolder(
    root, name: "search",
    script: """
      cat >> log.jsonl
      \(crossExtension ? "" : "echo '{\"items\":[]}'")
      """,
    fields: [
      "items": crossExtension ? [] : [item],
      "fields": [
        ["name": "query", "type": "text", "description": "Query"],
        ["name": "limit", "type": "number", "description": "Limit"],
        ["name": "link", "type": "choice", "description": "Site", "options": ["youtube", "vimeo"]],
      ],
    ])
  let model = LauncherModel.testing(in: root)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("yt")
  await nav.settled()
  let owner = crossExtension ? "extension:personal" : "extension:search"
  #expect(nav.selected?.provider == owner && nav.selected?.row.id == "item:yt")
  #expect(nav.fieldSlots.map(\.name) == ["query"])
  #expect(nav.moveFocus(1) && nav.focusedField == "query")
  nav.setField("query", to: "cats")
  #expect(nav.moveFocus(1) && nav.focusedField == nil)
  nav.setField("limit", to: "2")
  await nav.settled()
  #expect(nav.input == "yt" && nav.fieldValues == ["query": "cats"])
  #expect(try requests(in: folder).isEmpty)

  if byHotkey {
    model.press(HotkeyTarget(target: owner, item: "yt"))
  } else {
    nav.run()
  }
  await nav.settled()
  let sent = try requests(in: folder)
  let request = try #require(sent.first)
  #expect(sent.count == 1 && request.submitted && request.action == "search" && request.input == "cats")
  #expect(request.fields == ["query": "cats", "link": "youtube", "limit": "10"])
  if crossExtension {
    #expect(surface.effects == [.hide] && !surface.isShown && nav.command == nil)
  } else {
    #expect(surface.effects.isEmpty && surface.isShown && nav.command?.id == "extension:search")
  }
  await model.finish()
}

@MainActor @Test func aRootItemWithAllFieldsFixedHasNoTabStop() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "search",
    script: """
      cat >> log.jsonl
      echo '{"items":[]}'
      """,
    fields: [
      "items": [
        [
          "id": "cats", "title": "Find Cats",
          "actions": [["type": "run", "fields": ["query": "cats"]]],
        ]
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("Find Cats")
  await nav.settled()
  #expect(surface.presentation.selected?.row.id == "item:cats")
  #expect(nav.fieldSlots.isEmpty && !nav.moveFocus(1) && !nav.moveFocus(-1))

  nav.run()
  await nav.settled()
  let sent = try requests(in: folder)
  #expect(sent.count == 1 && sent.first?.fields == ["query": "cats"])
  await model.finish()
}

@MainActor @Test func rootKeywordFillsACommandAndTabReachesItsNextField() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Search",
    fields: [
      "keyword": "kw",
      "fields": [
        ["name": "query", "type": "text", "description": "Query"],
        ["name": "scope", "type": "text", "description": "Scope"],
      ],
    ])
  _ = try extensionFolder(
    root, name: "other", fields: ["name": "KW Café + cats", "keyword": "k Café + cats"])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()

  nav.editInput("kw")
  await nav.settled()
  #expect(nav.fieldValues.isEmpty && nav.fieldSlots.map(\.name) == ["query", "scope"])
  nav.editInput("kw   ")
  await nav.settled()
  #expect(nav.fieldValues.isEmpty && nav.fieldSlots.map(\.name) == ["query", "scope"])
  nav.editInput("k Café + cats")
  await nav.settled()
  #expect(surface.presentation.selected?.provider == "extension:other" && nav.fieldValues.isEmpty)

  let input = "KW Café + cats"
  nav.editInput(input)
  await nav.settled()
  #expect(surface.presentation.rows.first?.provider == "extension:search")
  #expect(surface.presentation.selected?.row.title == "Search")
  #expect(surface.presentation.selected?.row.subtitle == "Café + cats")
  #expect(surface.presentation.rows.contains { $0.row.actions.first == .send(input) })
  #expect(nav.fieldValues == ["query": "Café + cats"] && nav.focusedField == nil)
  #expect(nav.moveFocus(1) && nav.focusedField == "scope")
  nav.setField("scope", to: "videos")
  #expect(nav.input == input && nav.fieldValues == ["query": "Café + cats", "scope": "videos"])
  #expect(try requests().isEmpty)

  nav.run()
  await nav.settled()
  let sent = try #require(try requests().first)
  #expect(try requests().count == 1 && sent.submitted && sent.input == "Café + cats")
  #expect(sent.fields == ["query": "Café + cats", "scope": "videos"])
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func rootItemKeywordFillsTheFirstTextFieldThatIsntFixed(listEntry: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "search",
    script: """
      cat >> log.jsonl
      """,
    fields: [
      "fields": [
        ["name": "site", "type": "text", "description": "Site"],
        ["name": "query", "type": "text", "description": "Query"],
        ["name": "limit", "type": "number", "description": "Limit"],
      ]
    ])
  let item: [String: Any] = [
    "id": "youtube", "title": "Search YouTube", "keywords": ["yt"],
    "actions": [
      [
        "type": "run", "extension": "search", "hidden": true, "action": "open-link",
        "fields": ["site": "youtube", "limit": "10"],
      ]
    ],
  ]
  var owner: [String: Any] = ["command": NSNull(), "fields": [], "items": listEntry ? [] : [item]]
  if listEntry {
    owner["settings"] = [
      [
        "name": "searches", "type": "list", "description": "Searches",
        "fields": [["name": "title", "type": "text", "description": "Title"]],
        "item": item,
      ]
    ]
  }
  _ = try extensionFolder(root, name: "links", fields: owner)
  let model = LauncherModel.testing(in: root, bundled: nil)
  if listEntry {
    model.store.start(watching: false)
    model.store.change {
      try $0.set("links", to: ["searches": [["id": "youtube", "title": "Search YouTube"]]], in: "extensions")
    }
  }
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()

  nav.editInput("yt cats")
  await nav.settled()
  #expect(surface.presentation.selected?.row.id == (listEntry ? "entry:searches/youtube" : "item:youtube"))
  #expect(surface.presentation.selected?.row.title == "Search YouTube")
  #expect(surface.presentation.selected?.row.subtitle == "links · cats")
  #expect(nav.fieldValues == ["query": "cats"] && !nav.moveFocus(1))
  #expect(try requests(in: folder).isEmpty)

  nav.run()
  await nav.settled()
  let sent = try requests(in: folder)
  let request = try #require(sent.first)
  #expect(sent.count == 1 && request.submitted && request.action == "open-link")
  #expect(request.fields == ["site": "youtube", "query": "cats", "limit": "10"])
  #expect(surface.effects == [.hide])
  await model.finish()
}

@MainActor @Test func rootKeywordKeepsPatternResultsAndUsesTheUsualTieBreaks() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "pattern",
    script: """
      cat >> log.jsonl
      echo '{"items":[{"id":"match","title":"Pattern result","actions":[]}]}'
      """,
    fields: [
      "keyword": "kw", "match": "^kw ",
      "items": [["id": "a", "title": "A shortcut", "keywords": ["kw"], "actions": [["type": "run"]]]],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("kw cats")
  await nav.settled()
  #expect(surface.presentation.rows.map(\.row.id) == ["command", "item:a", "match", "ask"])
  #expect(try requests(in: folder).map(\.submitted) == [false])

  nav.run()
  await nav.settled()
  let sent = try requests(in: folder)
  #expect(sent.map(\.submitted) == [false, true] && sent.last?.fields == ["query": "cats"])
  await model.finish()
}

@MainActor @Test func theLongestRootKeywordWinsOverUsageAndCommandOrder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "git", script: "cat >> log.jsonl",
    fields: [
      "items": [
        ["id": "issue", "title": "Find a Git issue", "keywords": ["git issue"], "actions": [["type": "run"]]]
      ]
    ])
  let input = "git issue 123"
  let usage = UsageHistory(url: root.appending(path: "usage.json"))
  usage.record(
    Result(provider: "extension:git", row: Row(id: "command", title: "Git", actions: [])).id,
    input: input)
  let model = LauncherModel(history: usage, folder: root, bundled: nil)
  await model.extensions.reload()
  let nav = model.navigator
  nav.editInput(input)
  await nav.settled()
  #expect(nav.results.prefix(2).map(\.row.id) == ["item:issue", "command"])
  #expect(nav.selected?.row.id == "item:issue" && nav.fieldValues == ["query": "123"])

  nav.run()
  await nav.settled()
  let sent = try requests(in: folder)
  #expect(sent.count == 1 && sent.first?.submitted == true && sent.first?.fields == ["query": "123"])
  await model.finish()
}

@MainActor @Test func aRootItemTargetingASwitchedOffCommandHasNoFields() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let target = try extensionFolder(
    root, name: "search",
    script: """
      cat >> log.jsonl
      echo '{"items":[]}'
      """)
  _ = try extensionFolder(
    root, name: "personal",
    fields: [
      "command": NSNull(), "fields": [],
      "items": [
        ["id": "web", "title": "Search the Web", "actions": [["type": "run", "extension": "search"]]]
      ],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  model.store.update { $0.providers = [.init("extension:search", enabled: false)] }
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("Search the Web")
  await nav.settled()
  #expect(surface.presentation.selected?.row.id == "item:web")
  #expect(nav.fieldSlots.isEmpty && !nav.moveFocus(1))
  nav.setField("query", to: "cats")
  #expect(nav.fieldValues.isEmpty)

  nav.run()
  await nav.settled()
  #expect(surface.presentation.command == "extension:search")
  #expect(surface.presentation.problem?.contains("switched off") == true)
  #expect(try requests(in: target).isEmpty)
  await model.finish()
}

@MainActor @Test(arguments: ["item:42", "command"])
func aPatternResultHasNoFieldsEvenWithAManifestRowID(_ id: String) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "search",
    script: """
      cat >> log.jsonl
      echo '{"items":[{"id":"\(id)","title":"Find Cats","actions":[{"type":"run","input":"cats"}]}]}'
      """, fields: ["match": "^find "])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("find cats")
  await nav.settled()
  #expect(surface.presentation.selected?.row.id == id)
  #expect(nav.fieldSlots.isEmpty && !nav.moveFocus(1))

  nav.run()
  await nav.settled()
  let sent = try requests(in: folder)
  #expect(sent.map(\.submitted) == [false, true] && sent.last?.input == "cats")
  await model.finish()
}

@MainActor @Test(arguments: [false, true])
func aRootItemsLinkCannotReceiveTheDraftFromItsPreviousRun(byHotkey: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  func writeManifest(_ action: [String: String]) throws -> URL {
    try extensionFolder(
      root, name: "search",
      script: """
        cat >> log.jsonl
        echo '{"items":[]}'
        """,
      fields: [
        "keyword": "lookup", "items": [["id": "web", "title": "Search the Web", "actions": [action]]],
      ])
  }
  let folder = try writeManifest(["type": "run"])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("Search the Web")
  await nav.settled()
  let selection = try #require(surface.presentation.selection)
  #expect(nav.moveFocus(1) && nav.focusedField == "query")
  nav.setField("query", to: "draft")
  #expect(nav.fieldValues == ["query": "draft"])

  _ = try writeManifest(["type": "open", "url": "wicket://search?input=prefill"])
  await model.extensions.reload()
  await nav.settled()
  #expect(surface.presentation.selection == selection)
  #expect(nav.fieldSlots.isEmpty && nav.focusedField == nil)
  #expect(nav.returnAction == .run(Address(extensionName: "search", input: "prefill", link: true)))

  if byHotkey {
    model.press(HotkeyTarget(target: "extension:search", item: "web"))
  } else {
    nav.run()
  }
  await nav.settled()
  let sent = try requests(in: folder)
  #expect(sent.map(\.submitted) == [false] && sent.first?.fields == ["query": "prefill"])
  await model.finish()
}

@MainActor @Test func aRootItemWithoutSearchBarFieldsKeepsItsFirstAction() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "links",
    fields: [
      "items": [
        [
          "id": "bookmark", "title": "Bookmark",
          "actions": [["type": "copy", "text": "https://example.com"], ["type": "run"]],
        ],
        [
          "id": "folder", "title": "Folder",
          "actions": [["type": "open", "url": "wicket://links?input=bookmark"]],
        ],
      ]
    ])
  let model = LauncherModel.testing(in: root)
  let nav = model.navigator
  let surface = RecordingSurface()
  nav.surface = surface
  await model.extensions.reload()
  nav.editInput("bookmark")
  await nav.settled()
  let row = try #require(nav.selected)
  #expect(row.row.id == "item:bookmark")
  #expect(nav.fieldSlots.isEmpty && !nav.moveFocus(1))
  nav.run()
  #expect(surface.effects == [.run(.copy("https://example.com"), from: row)])
  nav.editInput("folder")
  await nav.settled()
  #expect(nav.selected?.row.id == "item:folder")
  #expect(nav.fieldSlots.isEmpty && !nav.moveFocus(1))
  #expect(nav.returnAction == .run(Address(extensionName: "links", input: "bookmark", link: true)))
  await model.finish()
}

@MainActor @Test func aSubmitCommandRunsOnlyWhenEnteredAndOnReturn() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Note",
    fields: ["fields": [["name": "text", "type": "text", "description": "Text"]], "submit": true])
  let fake = FakeTranscriber()
  let (model, controller) = voicedPanel(in: root, transcriber: { fake })
  await model.extensions.reload()
  model.navigator.input = "note"
  await model.navigator.settled()
  #expect(model.activateReturn())
  await model.navigator.settled()
  // Entering runs once, submitted, and nothing is selected: Return belongs to the input.
  #expect(model.navigator.submits && model.navigator.command?.id == "extension:note")
  #expect(try requests().map(\.submitted) == [true])
  #expect(model.navigator.results.count == 2 && model.navigator.selection == nil)
  // Typing and refreshes run nothing.
  model.navigator.input = "draft"
  model.navigator.refresh()
  model.navigator.sourcesChanged(["extension:note"])
  await model.navigator.settled()
  #expect(try requests().count == 1 && model.navigator.selection == nil)
  // Return sends one submitted request with the input and fields.
  #expect(
    model.navigator.returnAction == .run(Address(input: "draft"))
      && model.navigator.selected?.provider == "extension:note")
  #expect(model.activateReturn())
  await model.navigator.settled()
  var last = try #require(try requests().last)
  #expect(
    try requests().count == 2 && last.submitted && last.input == "draft"
      && last.fields == ["text": "draft"])
  #expect(model.navigator.input == "draft" && model.navigator.fieldValues == ["text": "draft"])
  // An arrow key enters the items and Return runs the selected one; typing and up leave them.
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.id == "again")
  model.navigator.input = "draft2"
  await model.navigator.settled()
  #expect(model.navigator.selection == nil)
  model.navigator.move(1)
  model.navigator.move(-1)
  #expect(model.navigator.selection == nil)
  model.navigator.move(1)
  #expect(model.activateReturn())
  await model.navigator.settled()
  last = try #require(try requests().last)
  #expect(try requests().count == 3 && last.submitted && last.fields == ["text": "again"])
  // Voice fills the input and runs nothing.
  model.store.update { $0.voice.enabled = true }
  controller.input.toggle()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("spoken words"))
  #expect(await eventually { model.navigator.input == "spoken words" })
  try await Task.sleep(for: .milliseconds(450))
  await model.navigator.settled()
  #expect(try requests().count == 3 && model.navigator.selection == nil)
  await controller.finish()
}

@MainActor @Test(arguments: [false, true])
func aPromptedActionSubmitsItsOwnOperationAndHides(submit: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root, name: "notes",
    fields: [
      "name": "Notes", "command": ["/usr/bin/python3", "main.py"], "submit": submit,
      "fields": [["name": "query", "type": "text", "description": "Query"]],
      "items": [
        [
          "id": "archive", "title": "Archive Note",
          "actions": [["type": "run", "action": "archive", "hidden": true, "promptIfEmpty": true]],
        ]
      ],
    ])
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    if r.get('action') != 'archive':
      print(json.dumps({'items':[{'id':'preview','title':'Preview Notes','actions':[]}]}))
    elif not r['input'].strip():
      print(json.dumps({'items':[{'id':'prompt','title':'Enter a note to archive','actions':[]}]}))
    else:
      open('archived','w').write(r['input'])
    """
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  let model = LauncherModel.testing(in: root)
  let navigator = model.navigator
  let surface = RecordingSurface()
  surface.shown = false
  navigator.surface = surface
  surface.onEffect = { if $0 == .hide { navigator.dismiss() } }
  await model.extensions.reload()

  let target = "extension:notes"
  model.press(HotkeyTarget(target: target))
  await navigator.settled()
  #expect(navigator.results.first?.row.title == "Preview Notes")

  model.press(HotkeyTarget(target: target, item: "archive"))
  await navigator.settled()
  #expect(surface.isShown && navigator.results.first?.row.title == "Enter a note to archive")
  #expect(try requests(in: folder).last?.action == "archive")
  #expect(model.activateReturn())
  await navigator.settled()
  #expect(surface.isShown && surface.count(.hide) == 0)
  #expect(navigator.results.first?.row.title == "Enter a note to archive")

  navigator.editInput("Wicket")
  await navigator.settled()
  #expect(try requests(in: folder).map(\.input) == ["", "", ""])
  #expect(model.activateReturn())
  await navigator.settled()
  let sent = try #require(try requests(in: folder).last)
  #expect(sent.submitted && sent.action == "archive" && sent.fields == ["query": "Wicket"])
  #expect(surface.count(.hide) == 1 && !surface.isShown)
  #expect(try String(contentsOf: folder.appending(path: "archived"), encoding: .utf8) == "Wicket")
  await model.finish()
}

/// Return can submit the fields again without replaying the named action.
@MainActor @Test func aSubmitNeverReplaysANamedAction() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    print(json.dumps({'items':[{'id':'3','title':'Note 3','actions':[
      {'type':'run','title':'Delete','action':'delete','fields':{'id':'3'}}]}]}))
    """
  let folder = try extensionFolder(
    root, name: "notes",
    fields: [
      "name": "Notes", "command": ["/usr/bin/python3", "main.py"],
      "fields": [["name": "text", "type": "text", "description": "Text"]],
      "submit": true,
    ])
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  func requests() throws -> [ProviderRequest] { try WicketTests.requests(in: folder) }
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  model.navigator.input = "notes"
  await model.navigator.settled()
  #expect(model.activateReturn())
  await model.navigator.settled()
  model.navigator.move(1)
  #expect(model.activateReturn())
  #expect(!model.activateReturn())
  await model.navigator.settled()
  #expect(try requests().last?.action == "delete" && requests().last?.fields == ["id": "3"])
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(try requests().last?.action == nil && requests().last?.fields == ["id": "3"])
  // The next note: the Delete is not part of what Return sends.
  model.navigator.input = "buy milk"
  #expect(model.navigator.returnAction == .run(Address(input: "buy milk")))
  #expect(model.activateReturn())
  await model.navigator.settled()
  let last = try #require(try requests().last)
  #expect(last.submitted && last.action == nil && last.fields == ["text": "buy milk", "id": "3"])
  // A conversation opened over the command offers no slots.
  model.navigator.input = ""
  model.navigator.askAgent()
  #expect(model.navigator.fieldSlots.isEmpty && model.navigator.focusedField == nil)
  await model.finish()
}

/// Headless `--extension` sends the input, the field values and action and `submitted` exactly as given, and
/// refuses fields that are not an object of strings.
@MainActor @Test func headlessExtensionRunsSendFieldsAndOneShotAction() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let (_, requests) = try logging(
    root, name: "Caffeinate",
    fields: ["fields": [["name": "hours", "type": "number", "description": "Hours"]]])
  let plain = try await cli(root, ["--extension", "caffeinate"])
  #expect(plain.0 == 0 && plain.1["items"].array.count == 2)
  let full = try await cli(
    root,
    [
      "--extension", "caffeinate", "--input", "now", "--fields", #"{"hours":"2"}"#, "--submitted", "--action",
      "record",
    ])
  #expect(full.0 == 0)
  #expect(
    try requests().map { [$0.input, $0.fields["hours"] ?? "-", String($0.submitted), $0.action ?? "-"] } == [
      ["", "-", "false", "-"], ["now", "2", "true", "record"],
    ])
  let refused = try await cli(root, ["--extension", "caffeinate", "--fields", #"["2"]"#, "--submitted"])
  #expect(try refused.0 == 1 && refused.1["error"].string != nil && requests().count == 2)
  let actionWithoutSubmit = try await cli(root, ["--extension", "caffeinate", "--action", "record"])
  #expect(try actionWithoutSubmit.0 == 1 && requests().count == 2)
  let help = try await cli(root, ["--help"])
  #expect(help.1["usage"].string?.contains("--fields JSON_OBJECT") == true)
}

@MainActor @Test func anOpenCommandRerunsOnlyForTheUserOrItsOwnChange() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (folder, requests) = try logging(root, name: "Password", fields: ["fields": []])
  _ = try extensionFolder(root, name: "other")
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  model.navigator.go(Address(id: "extension:password"))
  await model.navigator.settled()
  #expect(try requests().count == 1)
  // What does not concern it reruns nothing: an app rescan, another extension's change, a setting, or
  // another source switched off.
  model.navigator.sourcesChanged(["apps"])
  try Data(#"{"contract":2,"name":"Other","command":["/bin/sh","main.sh"],"icon":"star"}"#.utf8)
    .write(to: root.appending(path: "extensions/other/wicket.json"))
  await model.extensions.reload()
  #expect(model.extensions.commands["extension:other"]?.manifest.icon == "star")
  model.store.update { $0.backgroundTransparency = 0.5 }
  model.store.update { $0.providers = [.init("extension:other", enabled: false)] }
  await model.navigator.settled()
  #expect(try requests().count == 1)
  // Its own manifest changing or it being switched off and on does.
  var manifest =
    try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "wicket.json")))
    as! [String: Any]
  manifest["icon"] = "key"
  try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  await model.extensions.reload()
  await model.navigator.settled()
  #expect(try requests().count == 2)
  model.store.update { $0.providers = [.init("extension:password", enabled: false)] }
  model.store.update { $0.providers = [] }
  await model.navigator.settled()
  #expect(try requests().count == 3 && model.navigator.command?.problem == nil)
  await model.finish()
}

@MainActor @Test func switchingOffARunningSubmitCommandStopsIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root,
    script:
      "cat >/dev/null\nsleep 3\necho '{\"items\":[{\"id\":\"late\",\"title\":\"Late\",\"actions\":[]}]}'",
    fields: ["submit": true])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  model.navigator.go(Address(id: "test"), submitted: true)
  #expect(await eventually { model.navigator.command?.busy == true })
  // Switched off, it stops at once and says so, as any other command does.
  model.store.update { $0.providers = [.init("extension:test", enabled: false)] }
  #expect(
    model.navigator.command?.busy == false
      && model.navigator.command?.problem?.contains("switched off") == true)
  await model.finish()
}

@MainActor @Test func anAppRescanThatFindsTheSameAppsChangesNothing() async {
  let apps = AppsProvider()
  var changes = 0
  apps.onChange = { changes += 1 }
  await apps.rescan()
  await apps.rescan()
  #expect(changes == 1)
}

@MainActor @Test(arguments: [false, true])
func anUnclaimedCommandInputAsksAboutItsViewWithoutRerunning(submit: Bool) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Calendar",
    fields: [
      "fields": [
        ["name": "days", "type": "number", "description": "Days to show"],
        ["name": "allDay", "type": "bool", "description": "Show all-day events"],
        ["name": "layout", "type": "choice", "description": "Layout", "options": ["week", "month"]],
      ], "submit": submit,
    ])
  let model = LauncherModel.testing(in: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  await model.extensions.reload()
  model.navigator.go(Address(id: "calendar", input: "week"))
  await model.navigator.settled()
  #expect(model.navigator.presentation.commandPlaceholder == "Ask about Calendar…")
  #expect(model.navigator.presentation.returnAsksAgent && model.navigator.fieldSlots.map(\.name) == ["days"])
  #expect(model.navigator.input.isEmpty)
  #expect(model.activateReturn() && model.agent.active && model.agent.question.isEmpty)
  #expect(model.navigator.escape())

  model.navigator.editInput("What does this show?")
  await model.navigator.settled()
  #expect(try requests().map(\.input) == ["week"])
  #expect(model.activateReturn())
  #expect(await eventually { fake.running })
  #expect(fake.prompts.last?.text.contains("The user asked from the Calendar command") == true)
  #expect(fake.prompts.last?.text.contains("What does this show?") == true)
  #expect(try requests().count == 1)
  await model.finish()
}

@MainActor @Test func aRunActionMergesFieldsAndCanClearIndividualValues() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Weather",
    fields: [
      "fields": [
        ["name": "city", "type": "text", "description": "City"],
        ["name": "days", "type": "number", "description": "Days"],
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.go(Address(id: "weather", input: "Berlin"))
  await model.navigator.settled()
  model.navigator.setField("days", to: "7")
  await model.navigator.settled()
  let row = try #require(model.navigator.results.first)
  model.navigator.activate(.run(Address(fields: ["view": "hourly"], action: "show-hourly")), from: row)
  await model.navigator.settled()
  let merged = try #require(requests().last)
  #expect(
    merged.action == "show-hourly" && merged.fields == ["city": "Berlin", "days": "7", "view": "hourly"])
  #expect(model.navigator.fieldValues == merged.fields && model.navigator.input == "Berlin")
  model.navigator.activate(.run(Address(input: "Paris", fields: ["city": "", "days": ""])), from: row)
  await model.navigator.settled()
  let cleared = try #require(requests().last)
  #expect(cleared.input.isEmpty && cleared.fields == ["view": "hourly"])
  #expect(model.navigator.fieldValues == cleared.fields && model.navigator.input.isEmpty)
  await model.finish()
}
