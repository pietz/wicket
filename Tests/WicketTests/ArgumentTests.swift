import Foundation
import Testing

@testable import WicketApp

private func manifest(_ json: String) throws -> ExtensionManifest {
  try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
}

@Test func aManifestDeclaresArgumentsAndSubmitOnlyWithACommand() throws {
  let caffeinate = try manifest(
    #"{"name":"Caffeinate","command":["./main.py"],"arguments":[{"name":"hours","placeholder":"hours"},{"name":"minutes"}],"submit":true}"#
  )
  #expect(caffeinate.submit && caffeinate.arguments.map(\.name) == ["hours", "minutes"])
  #expect(caffeinate.arguments.map(\.placeholder) == ["hours", nil])
  let plain = try manifest(#"{"name":"Plain","command":["./main.py"]}"#)
  #expect(!plain.submit && plain.arguments.isEmpty)
  for invalid in [
    #"{"name":"A","command":["x"],"arguments":[{"name":""}]}"#,
    #"{"name":"A","command":["x"],"arguments":[{"name":"a"},{"name":"a"}]}"#,
    #"{"name":"A","command":["x"],"arguments":[{"name":"a"},{"name":"b"},{"name":"c"},{"name":"d"}]}"#,
    #"{"name":"A","command":["x"],"arguments":["a"]}"#,
    #"{"name":"A","command":["x"],"submit":"yes"}"#,
    #"{"name":"A","items":[],"arguments":[{"name":"a"}]}"#,
    #"{"name":"A","items":[],"submit":true}"#,
  ] {
    #expect(throws: (any Error).self, Comment(rawValue: invalid)) { try manifest(invalid) }
  }
}

/// A logging extension: every request is appended to `log.jsonl`, and the view lists one item that
/// runs with an argument.
@MainActor private func logging(
  _ root: URL, name: String, fields: [String: Any]
) throws -> (folder: URL, requests: () throws -> [ProviderRequest]) {
  let script = """
    import json,sys; r=json.load(sys.stdin)
    open('log.jsonl','a').write(json.dumps(r)+'\\n')
    print(json.dumps({'items':[{'id':'again','title':'Again','actions':[{'type':'run','arguments':{'text':'again'}}]},
      {'id':'other','title':'Other','actions':[]}]}))
    """
  var all: [String: Any] = ["name": name, "command": ["/usr/bin/python3", "main.py"]]
  all.merge(fields) { _, value in value }
  let folder = try extensionFolder(root, name: name.lowercased(), fields: all)
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  return (
    folder,
    {
      let log = (try? String(contentsOf: folder.appending(path: "log.jsonl"), encoding: .utf8)) ?? ""
      return try log.split(separator: "\n").map {
        try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8))
      }
    }
  )
}

@MainActor @Test func theModelOffersTheSelectedCommandsArgumentsAndEntersWithTheirValues() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Caffeinate",
    fields: ["arguments": [["name": "hours", "placeholder": "hours"], ["name": "minutes"]]])
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  model.input = "caff"
  await model.settled()
  // The command row is selected, so its arguments are on offer, all unfilled.
  let row = try #require(model.selected)
  #expect(row.row.id == "command" && row.provider == "extension:caffeinate")
  #expect(model.declaredArguments.map(\.name) == ["hours", "minutes"] && model.argumentValues.isEmpty)
  model.setArgument("hours", to: "4")
  model.setArgument("minutes", to: "")
  model.setArgument("seconds", to: "9")
  #expect(model.argumentValues == ["hours": "4"])
  #expect(try requests().isEmpty)
  // Another row has none and drops the values; dismissing drops them too.
  let ask = try #require(model.results.first { $0.provider == "agent" })
  model.select(ask.id)
  #expect(model.declaredArguments.isEmpty && model.argumentValues.isEmpty)
  model.select(row.id)
  #expect(model.argumentValues.isEmpty)
  model.setArgument("hours", to: "1")
  model.dismiss()
  model.input = "caff"
  await model.settled()
  #expect(model.selected?.id == row.id && model.argumentValues.isEmpty)
  // Return enters the command with the filled values as its arguments, in a chosen request.
  model.setArgument("hours", to: "4")
  model.setArgument("minutes", to: "30")
  #expect(
    model.returnAction
      == .run(Address(id: "extension:caffeinate", input: "", arguments: ["hours": "4", "minutes": "30"])))
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.command?.arguments == ["hours": "4", "minutes": "30"])
  #expect(try requests().map(\.chosen) == [true])
  #expect(try requests().last?.arguments == ["hours": "4", "minutes": "30"])
  // Inside, the same arguments are on offer with the command's values; an edit reruns like typing.
  #expect(model.declaredArguments.map(\.name) == ["hours", "minutes"])
  #expect(model.argumentValues == ["hours": "4", "minutes": "30"])
  model.setArgument("minutes", to: "")
  await model.settled()
  #expect(model.argumentValues == ["hours": "4"])
  #expect(try requests().last.map { !$0.chosen && $0.arguments == ["hours": "4"] } == true)
  // A run action replaces them, as declared arguments are ordinary arguments.
  model.select(try #require(model.results.first { $0.row.id == "again" }).id)
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.argumentValues == ["text": "again"])
  await model.finish()
}

@MainActor @Test func aSubmitCommandRunsOnlyWhenEnteredAndOnReturn() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (_, requests) = try logging(
    root, name: "Note", fields: ["arguments": [["name": "text"]], "submit": true])
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  await model.extensions.reload()
  model.input = "note"
  await model.settled()
  #expect(model.activateReturn())
  await model.settled()
  // Entering runs once, chosen, and nothing is selected: Return belongs to the input.
  #expect(model.submits && model.command?.id == "extension:note")
  #expect(try requests().map(\.chosen) == [true])
  #expect(model.results.count == 2 && model.selection == nil)
  // Typing, filling an argument and a refresh run nothing.
  model.input = "draft"
  model.setArgument("text", to: "hello")
  model.refresh()
  model.catalogChanged()
  await model.settled()
  #expect(try requests().count == 1 && model.selection == nil)
  // Return sends one chosen request with the input and the arguments.
  #expect(
    model.returnAction == .run(Address(input: "draft", arguments: ["text": "hello"]))
      && model.selected?.provider == "extension:note")
  #expect(model.activateReturn())
  await model.settled()
  var last = try #require(try requests().last)
  #expect(
    try requests().count == 2 && last.chosen && last.input == "draft" && last.arguments == ["text": "hello"])
  #expect(model.input == "draft" && model.argumentValues == ["text": "hello"])
  // An arrow key enters the items and Return runs the selected one; typing and up leave them.
  model.move(1)
  #expect(model.selected?.row.id == "again")
  model.input = "draft2"
  await model.settled()
  #expect(model.selection == nil)
  model.move(1)
  model.move(-1)
  #expect(model.selection == nil)
  model.move(1)
  #expect(model.activateReturn())
  await model.settled()
  last = try #require(try requests().last)
  #expect(try requests().count == 3 && last.chosen && last.arguments == ["text": "again"])
  // Voice fills the input and runs nothing.
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("spoken words"))
  #expect(await eventually { model.input == "spoken words" })
  try await Task.sleep(for: .milliseconds(450))
  await model.settled()
  #expect(try requests().count == 3 && model.selection == nil)
  await model.finish()
}

/// The note example through the real pipeline: only a chosen request with a text writes, and every
/// request shows the newest notes first. `--arguments` is a JSON object; an array is refused.
@MainActor @Test func theNoteExampleAppendsOnlyOnAChosenRequestWithAText() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  let folder = root.appending(path: "extensions/note")
  try FileManager.default.copyItem(at: root.appending(path: "examples/note"), to: folder)
  let note = try JSONDecoder().decode(
    ExtensionManifest.self, from: Data(contentsOf: folder.appending(path: "wicket.json")))
  #expect(note.submit && note.arguments.map(\.name) == ["text"])
  func titles(_ arguments: [String]) async throws -> [String?] {
    let output = try await cli(root, ["--extension", "note"] + arguments)
    #expect(output.0 == 0)
    return output.1["items"].array.map { $0["title"].string }
  }
  #expect(try await titles(["--arguments", #"{"text":"unchosen"}"#]) == [])
  #expect(try await titles(["--arguments", #"{"text":"buy milk"}"#, "--chosen"]) == ["buy milk"])
  #expect(try await titles(["--chosen"]) == ["buy milk"])
  #expect(
    try await titles(["--arguments", #"{"text":"call  Ada"}"#, "--chosen"]) == ["call Ada", "buy milk"])
  let notes = try String(contentsOf: folder.appending(path: "notes.md"), encoding: .utf8)
  #expect(notes.split(separator: "\n").count == 2 && notes.hasSuffix(" call Ada\n"))
  let refused = try await cli(root, ["--extension", "note", "--arguments", #"["buy milk"]"#, "--chosen"])
  #expect(refused.0 == 1 && refused.1["error"].string != nil)
  let help = try await cli(root, ["--help"])
  #expect(help.1["usage"].string?.contains("--arguments JSON_OBJECT") == true)
}
