import Foundation
import Testing

@testable import WicketApp

/// A registration handle: alive while the fake registration holds it.

@Test func aHotkeyTargetSpellsItsAddressAndReadsItBack() throws {
  let item = HotkeyTarget(target: "extension:window", item: "left")
  #expect(item.description == "wicket://window?item=left")
  #expect(HotkeyTarget("wicket://window?item=left") == item)
  #expect(HotkeyTarget("wicket:window?item=left") == item)
  #expect(HotkeyTarget("wicket://clipboard")?.target == "clipboard")
  #expect(HotkeyTarget("wicket://Settings") == HotkeyTarget(target: "settings"))
  #expect(HotkeyTarget("wicket://?input=calc") == HotkeyTarget(target: nil, input: "calc"))
  #expect(HotkeyTarget("https://window") == nil)
  // A folder and an item id with spaces and query characters survive the round trip.
  let odd = HotkeyTarget(target: "extension:my tools", input: "a+b", item: "x&y=z")
  #expect(HotkeyTarget(odd.description) == odd)
  // Followed as a link it is the command, never chosen.
  #expect(item.address == Address(extensionName: "window", link: true))
  #expect(HotkeyTarget(target: "settings").address.targetID == "settings")
}

@MainActor @Test func hotkeysAreStoredInConfigAndReadBack() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "config.json")
  try Data(#"{"hotkey":"option+space","future":1}"#.utf8).write(to: url)
  let file = ConfigurationFile(url: url)
  let left = HotkeyTarget(target: "extension:window", item: "left")
  let clipboard = HotkeyTarget(target: "clipboard")
  try file.bind(Shortcut("ctrl+option+left"), to: left)
  try file.bind(Shortcut("option+v"), to: clipboard)
  var text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.contains(#""address" : "wicket://window?item=left""#))
  #expect(text.contains(#""keys" : "ctrl+option+left""#) && text.contains("future"))
  var config = try Configuration.load(at: url)
  #expect(config.hotkeys.map(\.target) == [left, clipboard])
  #expect(config.hotkeys.first?.keys.symbols == "⌃⌥←")
  // Changing keeps the entry's place and its unknown fields; nil removes it.
  var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  var entries = object["hotkeys"] as! [[String: Any]]
  entries[0]["note"] = "mine"
  object["hotkeys"] = entries
  try JSONSerialization.data(withJSONObject: object).write(to: url)
  try file.bind(Shortcut("ctrl+option+h"), to: left)
  try file.bind(nil, to: clipboard)
  config = try Configuration.load(at: url)
  #expect(config.hotkeys.map(\.keys.description) == ["ctrl+option+h"])
  text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.contains("mine"))
  // A second binding for one address, a non-Wicket address or keys that take typing are invalid files.
  for hotkeys in [
    #"[{"keys":"f5","address":"wicket://clipboard"},{"keys":"f6","address":"wicket:clipboard"}]"#,
    #"[{"keys":"f5","address":"https://example.com"}]"#,
    #"[{"keys":"shift+v","address":"wicket://clipboard"}]"#,
  ] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Configuration.self, from: Data(#"{"hotkeys":\#(hotkeys)}"#.utf8))
    }
  }
}

@MainActor @Test func aConflictingHotkeyKeepsTheWorkingOneAndCostsNoOther() throws {
  var taken: Set<Shortcut> = []
  var live: [Shortcut: () -> Void] = [:]
  final class Registration {
    let release: () -> Void
    init(_ release: @escaping () -> Void) { self.release = release }
    deinit { release() }
  }
  let hotkeys = CommandHotKeys { shortcut, press in
    guard !taken.contains(shortcut), live[shortcut] == nil else { return nil }
    live[shortcut] = press
    return Registration { live[shortcut] = nil }
  }
  var pressed: [HotkeyTarget] = []
  hotkeys.onPress = { pressed.append($0) }
  let left = HotkeyTarget(target: "extension:window", item: "left")
  let right = HotkeyTarget(target: "extension:window", item: "right")
  let launcher = try Shortcut("option+space")
  let h = try Shortcut("ctrl+option+h")
  let l = try Shortcut("ctrl+option+l")
  #expect(hotkeys.apply([.init(keys: h, target: left)], launcher: launcher) == nil)
  live[h]?()
  #expect(pressed == [left])
  // Taken by another app: the working binding stays, in the file and registered.
  taken.insert(l)
  #expect(hotkeys.set(l, for: left, launcher: launcher)?.contains("⌃⌥H still works") == true)
  #expect(hotkeys.inEffect(left) == h)
  // Command and a letter, the launcher's shortcut and another binding's are refused the same way.
  #expect(hotkeys.set(try Shortcut("cmd+c"), for: left, launcher: launcher)?.contains("Add Control") == true)
  #expect(hotkeys.set(launcher, for: right, launcher: launcher)?.contains("opens Wicket") == true)
  #expect(hotkeys.set(h, for: right, launcher: launcher)?.contains("wicket://window?item=left") == true)
  #expect(hotkeys.inEffect(left) == h && hotkeys.inEffect(right) == nil)
  // One conflict in the file costs only that binding.
  let problems = hotkeys.apply(
    [.init(keys: h, target: left), .init(keys: l, target: right)], launcher: launcher)
  #expect(problems?.contains("⌃⌥L") == true && hotkeys.inEffect(left) == h)
  // While a recorder listens none fires; resuming registers them again.
  hotkeys.pause(true)
  #expect(live.isEmpty)
  #expect(hotkeys.apply([.init(keys: h, target: left)], launcher: launcher) == nil && live.isEmpty)
  hotkeys.pause(false)
  #expect(hotkeys.apply([.init(keys: h, target: left)], launcher: launcher) == nil)
  #expect(live[h] != nil)
  // Gone from the file, gone from the system.
  #expect(hotkeys.apply([], launcher: launcher) == nil)
  #expect(live.isEmpty && hotkeys.inEffect(left) == nil)
}

@MainActor @Test func settingAHotkeyRegistersBeforeSavingAndAConflictSavesNothing() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigurationStore(url: root.appending(path: "config.json"))
  store.start(watching: false)
  var registered: [Shortcut?] = []
  var refuse = false
  store.applyBinding = { keys, _ in
    registered.append(keys)
    return refuse ? "in use" : nil
  }
  let left = HotkeyTarget(target: "extension:window", item: "left")
  store.bind(try Shortcut("ctrl+option+left"), to: left)
  #expect(store.configuration.hotkeys.map(\.target) == [left] && store.bindingProblem == nil)
  refuse = true
  store.bind(try Shortcut("ctrl+option+h"), to: left)
  #expect(store.bindingProblem == "in use")
  #expect(store.configuration.hotkeys.first?.keys.description == "ctrl+option+left")
  refuse = false
  store.bind(nil, to: left)
  #expect(store.configuration.hotkeys.isEmpty && registered.count == 3)
}

/// A Window-like extension: manifest items whose `run` sets `move`, and a program that writes each
/// request it gets to `requests`, fails when `move` is `fail`, is done (`close`) when it is `left` and
/// otherwise lists `left` under a row saying why nothing moved, as Window does.
@MainActor private func windowLike(_ root: URL) async throws -> LauncherModel {
  let item = { (id: String) -> [String: Any] in
    ["id": id, "title": id, "actions": [["type": "run", "arguments": ["move": id]]]]
  }
  _ = try extensionFolder(
    root, name: "mover",
    script: """
      line=$(cat); echo "$line" >> "\(root.path)/requests"
      case "$line" in *'"move":"fail"'*) echo broke >&2; exit 3;; *'"move":"left"'*) echo '{"close":true}'; exit;; esac
      echo '{"items":[{"id":"why","title":"Nothing moved","actions":[]},{"id":"left","title":"left","actions":[]}]}'
      """,
    fields: [
      "name": "Mover",
      "items": [
        item("left"), item("fail"), item("stuck"),
        ["id": "page", "title": "Page", "actions": [["type": "open", "url": "wicket://mover?input=x"]]],
      ],
    ])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  return model
}

@MainActor @Test func pressingAnItemsHotkeyRunsItChosenWithoutThePanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  var shown = 0
  await model.press(HotkeyTarget(target: "extension:mover", item: "left")) { shown += 1 }
  #expect(shown == 0 && model.command == nil)
  let request = try JSONDecoder().decode(
    ProviderRequest.self, from: Data(contentsOf: root.appending(path: "requests")))
  #expect(request.chosen && request.arguments == ["move": "left"] && request.input == "")
}

@MainActor @Test func aFailedBackgroundRunShowsThePanelWithItsReport() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  var shown = 0
  await model.press(HotkeyTarget(target: "extension:mover", item: "fail")) { shown += 1 }
  #expect(shown == 1 && model.command?.id == "extension:mover")
  let problem = try #require(model.command?.problem)
  #expect(problem.contains("broke") && problem.contains(#""move":"fail""#))
  // The report is what shows; the program ran once and does not run again.
  await model.settled()
  #expect(model.command?.problem != nil)
  let runs = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
  #expect(runs.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
}

@MainActor @Test func aBackgroundRunWhoseViewIsNotDoneShowsThePanelOnIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  var shown = 0
  await model.press(HotkeyTarget(target: "extension:mover", item: "stuck")) { shown += 1 }
  #expect(shown == 1 && model.command?.id == "extension:mover" && model.command?.problem == nil)
  #expect(model.results.first?.row.title == "Nothing moved" && model.selected?.row.id == "why")
  // What shows is the view of the run the hotkey caused; nothing runs again.
  await model.settled()
  let runs = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
  #expect(runs.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 1)
}

@MainActor @Test func aHotkeyForAViewOpensThePanelOnIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  var shown = 0
  // The command itself: entered as a link would, so its request is not chosen.
  await model.press(HotkeyTarget(target: "extension:mover")) { shown += 1 }
  #expect(shown == 1)
  #expect(await eventually { model.command?.id == "extension:mover" && model.command?.busy == false })
  // An item whose action opens a view goes there.
  _ = model.escape()
  await model.settled()
  await model.press(HotkeyTarget(target: "extension:mover", item: "page")) { shown += 1 }
  #expect(shown == 2)
  #expect(await eventually { model.command?.id == "extension:mover" && model.input == "x" })
  await model.settled()
  let requests = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
  #expect(!requests.contains(#""chosen":true"#))
  // A host command.
  var settings = 0
  model.onSettings = { settings += 1 }
  await model.press(HotkeyTarget(target: "settings")) { shown += 1 }
  #expect(shown == 3 && settings == 1)
}

@MainActor @Test func rowsWithAnAddressOfferAHotkeyAndShowIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  let left = HotkeyTarget(target: "extension:mover", item: "left")
  model.store.bind(try Shortcut("ctrl+option+left"), to: left)
  model.input = "left"
  await model.settled()
  let row = try #require(model.results.first { $0.row.id == "item:left" })
  #expect(model.hotkeyTarget(of: row) == left && model.hotkey(of: row)?.symbols == "⌃⌥←")
  model.input = "mover"
  await model.settled()
  let command = try #require(model.results.first { $0.row.id == "command" })
  #expect(model.hotkeyTarget(of: command) == HotkeyTarget(target: "extension:mover"))
  #expect(model.hotkey(of: command) == nil)
  model.input = "settings"
  await model.settled()
  let settings = try #require(model.results.first { $0.provider == "settings" })
  #expect(model.hotkeyTarget(of: settings) == HotkeyTarget(target: "settings"))
  // Inside the command its items carry their own ids.
  model.go(Address(extensionName: "mover"))
  #expect(await eventually { model.command?.id == "extension:mover" && model.command?.busy == false })
  let inside = try #require(model.results.first { $0.row.id == "left" })
  #expect(model.hotkey(of: inside)?.symbols == "⌃⌥←")
  // An app, a file or a fallback has no address of its own.
  #expect(model.hotkeyTarget(of: Result(provider: "apps", row: Row(id: "x", title: "X", actions: []))) == nil)
}

@MainActor @Test func setHotkeyRecordsWithEveryHotkeyPausedUntilThePanelHides() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = try await windowLike(root)
  var pauses: [Bool] = []
  model.pauseHotkeys = { pauses.append($0) }
  model.input = "left"
  await model.settled()
  let row = try #require(model.results.first { $0.row.id == "item:left" })
  model.recordHotkey(for: row)
  #expect(model.recorder.isRecording && model.recordsHotkey(of: row) && pauses == [true])
  model.dismiss()
  #expect(!model.recorder.isRecording && model.recorder.target == nil && pauses == [true, false])
  // A row without an address records nothing.
  model.recordHotkey(for: Result(provider: "apps", row: Row(id: "x", title: "X", actions: [])))
  #expect(!model.recorder.isRecording && pauses == [true, false])
}
