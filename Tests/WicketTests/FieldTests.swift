import Foundation
import Testing

@testable import WicketApp

private func manifest(_ json: String) throws -> ExtensionManifest {
  try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
}

@Test func aManifestDeclaresTypedFields() throws {
  let caffeinate = try manifest(
    #"{"name":"Caffeinate","command":["./main.py"],"fields":[{"name":"hours","type":"number","description":"Hours","placeholder":"hours"},{"name":"minutes","type":"number","description":"Minutes"}],"submit":true}"#
  )
  #expect(caffeinate.submit && caffeinate.fields.map(\.name) == ["hours", "minutes"])
  #expect(caffeinate.fields.map(\.placeholder) == ["hours", nil])
  let plain = try manifest(#"{"name":"Plain","command":["./main.py"]}"#)
  #expect(!plain.submit && plain.fields.isEmpty)
  for invalid in [
    #"{"name":"A","command":["x"],"fields":[{"name":"","type":"text","description":"Empty name"}]}"#,
    #"{"name":"A","command":["x"],"fields":[{"name":"a","type":"text","description":"A"},{"name":"a","type":"text","description":"A"}]}"#,
    #"{"name":"A","command":["x"],"fields":[{"name":"a","type":"text","description":"A"},{"name":"b","type":"text","description":"B"},{"name":"c","type":"text","description":"C"},{"name":"d","type":"text","description":"D"}]}"#,
    #"{"name":"A","command":["x"],"fields":["a"]}"#,
    #"{"name":"A","command":["x"],"submit":"yes"}"#,
    #"{"name":"A","items":[],"submit":true}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"choice","description":"A"}]}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"choice","description":"A","options":["x","x"]}]}"#,
    #"{"name":"A","items":[],"fields":[{"name":"a","type":"widget","description":"A"}]}"#,
    #"{"name":"A","command":["x"],"arguments":["a"]}"#,
  ] {
    #expect(throws: (any Error).self, Comment(rawValue: invalid)) { try manifest(invalid) }
  }
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
  // A run action replaces them, with supplied field values.
  model.navigator.select(try #require(model.navigator.results.first { $0.row.id == "again" }).id)
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.fieldValues == ["text": "again"])
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
  defer { try? FileManager.default.removeItem(at: root) }
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
  try Data(#"{"name":"Other","command":["/bin/sh","main.sh"],"icon":"star"}"#.utf8)
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
