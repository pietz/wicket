import AppKit
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
  let user = HotkeyTarget(target: odd.target, input: odd.input, item: odd.item, isUserItem: true)
  #expect(HotkeyTarget(user.description) == user)
  #expect(HotkeyTarget("wicket://window?item=left&user-item=left") == nil)
  #expect(Address(url: try #require(URL(string: user.description))) == user.address)
  // Followed as a link it is the command, never submitted.
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
  #expect(store.configuration.hotkeys.map(\.target) == [left] && store.rejection == nil)
  refuse = true
  store.bind(try Shortcut("ctrl+option+h"), to: left)
  #expect(store.rejection?.target == left && store.rejection?.problem == "in use")
  #expect(store.configuration.hotkeys.first?.keys.description == "ctrl+option+left")
  refuse = false
  store.bind(nil, to: left)
  #expect(store.configuration.hotkeys.isEmpty && registered.count == 3)
}

/// A Window-like extension: manifest items whose hidden `run` names an action, and a program that writes each
/// request it gets to `requests`, fails when its action is `fail`, is done with nothing to show when it is
/// `left` and otherwise lists `left` under a row saying why nothing moved, as Window does. `show` is a run
/// that is not hidden and answers once `release` exists; `page` opens the command as a link.
@MainActor private func windowLike(_ root: URL, scanned: Bool = true) async throws -> (
  LauncherModel, RecordingSurface
) {
  let item = { (id: String) -> [String: Any] in
    ["id": id, "title": id, "actions": [["type": "run", "action": id, "hidden": id != "show"]]]
  }
  _ = try extensionFolder(
    root, name: "mover",
    script: """
      line=$(cat); echo "$line" >> "\(root.path)/requests"
      case "$line" in
        *'"action":"fail"'*) echo broke >&2; exit 3;;
        *'"action":"left"'*) exit;;
        *'"action":"show"'*) while [ ! -e "\(root.path)/release" ]; do sleep 0.01; done;;
      esac
      echo '{"items":[{"id":"why","title":"Nothing moved","actions":[]},{"id":"left","title":"left","actions":[{"type":"run","action":"left","hidden":true}]}]}'
      """,
    fields: [
      "name": "Mover",
      "items": [
        item("left"), item("fail"), item("stuck"), item("show"),
        ["id": "page", "title": "Page", "actions": [["type": "open", "url": "wicket://mover?input=x"]]],
        ["id": "copy", "title": "Copy", "actions": [["type": "copy", "text": "moved"]]],
        ["id": "script", "title": "Script", "actions": [["type": "open", "url": "file:///bin/sh"]]],
      ],
    ])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  if scanned { await model.extensions.reload() }
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  return (model, surface)
}
private func runs(_ root: URL) throws -> [ProviderRequest] {
  try String(contentsOf: root.appending(path: "requests"), encoding: .utf8).split(separator: "\n").map {
    try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8))
  }
}

@MainActor @Test func pressingAHiddenItemsHotkeyRunsItSubmittedWithoutThePanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root)
  model.press(HotkeyTarget(target: "extension:mover", item: "left"))
  await model.navigator.settled()
  // Not hidden again either, which would restart a kept conversation's time.
  #expect(surface.effects.isEmpty && model.navigator.command == nil)
  let request = try #require(try runs(root).first)
  #expect(request.submitted && request.action == "left" && request.input == "")
}

/// Pressed during the first extension scan, an item's hotkey waits for it and runs the item, not its command.
@MainActor @Test func anItemsHotkeyPressedBeforeTheFirstScanRunsTheItem() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root, scanned: false)
  model.press(HotkeyTarget(target: "extension:mover", item: "left"))
  await model.extensions.reload()
  #expect(await eventually { (try? runs(root))?.count == 1 })
  await model.navigator.settled()
  #expect(surface.shows == 0 && model.navigator.command == nil)
  #expect(try runs(root).first?.action == "left")
  await model.finish()
}

@MainActor @Test func aFailedHiddenRunShowsThePanelWithItsReport() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root)
  model.press(HotkeyTarget(target: "extension:mover", item: "fail"))
  await model.navigator.settled()
  #expect(surface.shows == 1 && model.navigator.command?.id == "extension:mover")
  let problem = try #require(model.navigator.command?.problem)
  #expect(problem.contains("broke") && problem.contains(#""action":"fail""#))
  // The report is what shows; the program ran once and does not run again.
  await model.navigator.settled()
  #expect(model.navigator.command?.problem != nil)
  #expect(try runs(root).count == 1)
}

@MainActor @Test func aHiddenRunWithAViewShowsThePanelOnIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root)
  model.press(HotkeyTarget(target: "extension:mover", item: "stuck"))
  await model.navigator.settled()
  #expect(
    surface.shows == 1 && model.navigator.command?.id == "extension:mover"
      && model.navigator.command?.problem == nil)
  #expect(
    model.navigator.results.first?.row.title == "Nothing moved" && model.navigator.selected?.row.id == "why")
  // What shows is the view of the run the hotkey caused; nothing runs again.
  await model.navigator.settled()
  #expect(try runs(root).count == 1)
}

@MainActor @Test func aHotkeyForAViewOpensThePanelOnItAtOnce() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root)
  // The command itself: shown at once, entered as a link would, so its request is not submitted.
  model.press(HotkeyTarget(target: "extension:mover"))
  #expect(surface.shows == 1 && model.navigator.command?.id == "extension:mover")
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Nothing moved")
  // An item whose action opens a view goes there.
  surface.perform(.hide)
  model.navigator.dismiss()
  model.press(HotkeyTarget(target: "extension:mover", item: "page"))
  #expect(model.navigator.command?.id == "extension:mover" && model.navigator.input == "x")
  await model.navigator.settled()
  #expect(try runs(root).allSatisfy { !$0.submitted })
  // A host command.
  model.press(HotkeyTarget(target: "settings"))
  #expect(surface.shows == 2 && surface.count(.settings) == 1)
}

/// An item whose first action is a copy, paste, open or reveal does it without the panel, as Return on the
/// item would; one that cannot be done shows the panel with why.
@MainActor @Test func aHotkeysCopyIsDoneWithoutThePanel() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, surface) = try await windowLike(root)
  model.press(HotkeyTarget(target: "extension:mover", item: "copy"))
  #expect(surface.effects == [.run(.copy("moved"), from: nil)] && model.navigator.command == nil)
  model.press(HotkeyTarget(target: "extension:mover", item: "script"))
  #expect(
    surface.shows == 1 && model.navigator.actionProblem?.contains("does not open scripts") == true)
  #expect(surface.effects.count == 1 && model.navigator.command == nil)
  // The next hotkey's screen does not carry that failure.
  model.press(HotkeyTarget(target: "extension:mover"))
  #expect(model.navigator.actionProblem == nil)
  await model.navigator.settled()
  #expect(model.navigator.command?.id == "extension:mover" && model.navigator.actionProblem == nil)
}

/// A direct hotkey's copy, paste, open or reveal ends by hiding the panel, which is already hidden then: a
/// kept conversation's time still runs from when it was hidden. (The hide is called directly: the copy
/// itself would write the real pasteboard.)
@MainActor @Test func aDirectHotkeyDoesNotReviveAKeptConversation() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let controller = PaletteController(model: model, panel: FrontRecordingPanel())
  model.navigator.surface = controller
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "Question"
  model.navigator.send()
  #expect(await eventually { fake.running })
  fake.text("Answer")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  model.agent.retention = 0.2
  controller.hide()
  try await Task.sleep(for: .milliseconds(300))
  controller.hide()
  model.reopen()
  #expect(!model.agent.active)
  await model.finish()
}

/// The Settings hotkey leaves for the Settings window: the launcher is never ordered front over it.
@MainActor @Test func theSettingsHotkeyNeverShowsTheLauncher() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let panel = FrontRecordingPanel()
  let controller = PaletteController(model: model, panel: panel)
  var fronted = 0
  panel.onFront = { fronted += 1 }
  model.navigator.surface = controller
  model.press(HotkeyTarget(target: "settings"))
  #expect(fronted == 0 && !controller.isShown)
  await model.finish()
}

/// An answer that ended while hidden keeps its menu bar dot through a visit to Settings: only the
/// launcher showing clears it.
@MainActor @Test func theMenuBarDotOutlastsSettings() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let controller = PaletteController(model: model, panel: FrontRecordingPanel())
  model.navigator.surface = controller
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "Question"
  model.navigator.send()
  #expect(await eventually { fake.running })
  controller.hide()
  fake.text("Answer")
  fake.end()
  #expect(await eventually { !model.agent.busy })
  #expect(model.agent.waiting)
  model.press(HotkeyTarget(target: "settings"))
  #expect(model.agent.waiting)
  controller.show(orderFront: false, listen: false)
  #expect(!model.agent.waiting)
  await model.finish()
}

/// A panel that records what its controller holds each time it would be ordered front, and never is.
@MainActor private final class FrontRecordingPanel: PalettePanel {
  var onFront: () -> Void = {}
  override var isKeyWindow: Bool { true }
  override func makeKeyAndOrderFront(_ sender: Any?) { onFront() }
  override func orderFrontRegardless() { onFront() }
}

/// A run that is not hidden opens the panel on its command at once, through a real panel's showing: as it
/// is ordered front it holds the command, never the root, and the request is sent once, submitted.
/// Pressed again while it runs, nothing happens.
@MainActor @Test func aVisibleRunsHotkeyShowsItsCommandAtOnceAndSendsOneRequest() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let panel = FrontRecordingPanel()
  let controller = PaletteController(model: model, panel: panel)
  var fronted: [String] = []
  panel.onFront = { fronted.append(controller.presentation.command ?? "root") }
  let surface = RecordingSurface(wrapping: controller)
  model.navigator.surface = surface
  let show = HotkeyTarget(target: "extension:mover", item: "show")
  model.press(show)
  #expect(controller.isShown && model.navigator.command?.id == "extension:mover")
  #expect(!fronted.isEmpty && fronted.allSatisfy { $0 == "extension:mover" })
  #expect(controller.presentation.busy && model.navigator.command?.busy == true)
  #expect(await eventually { (try? runs(root).count) == 1 })
  model.press(show)
  try await Task.sleep(for: .milliseconds(100))
  try Data().write(to: root.appending(path: "release"))
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Nothing moved")
  let sent = try runs(root)
  #expect(sent.count == 1 && sent[0].submitted && sent[0].action == "show")
  // Over the open panel it is followed like a link, which holds the screen shown until it answers.
  model.press(show)
  #expect(await eventually { (try? runs(root).count) == 2 })
  controller.hide()
  await model.finish()
}

/// An external `wicket://` URL takes the hotkeys' way: the hidden panel is ordered front already on its
/// command, never the root, without listening, and the request is sent once, as a link's.
@MainActor @Test func anExternalURLShowsItsCommandAtOnceWithoutListening() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let panel = FrontRecordingPanel()
  let voice = FakeTranscriber()
  let controller = PaletteController(model: model, panel: panel, transcriber: { voice })
  var fronted: [String] = []
  panel.onFront = { fronted.append(controller.presentation.command ?? "root") }
  model.navigator.surface = controller
  controller.open(URL(string: "wicket://mover?input=x")!)
  #expect(controller.isShown && !fronted.isEmpty && fronted.allSatisfy { $0 == "extension:mover" })
  await model.navigator.settled()
  #expect(model.navigator.results.first?.row.title == "Nothing moved" && voice.feeds.isEmpty)
  let sent = try runs(root)
  #expect(sent.count == 1 && !sent[0].submitted && sent[0].input == "x")
  controller.hide()
  await model.finish()
}

/// A launch by URL never shows the root: URLs delivered before setup open their addresses in its place, and
/// a URL launch whose URL is still to come shows nothing until it arrives.
@MainActor @Test func aLaunchByURLShowsOnlyItsAddress() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let panel = FrontRecordingPanel()
  let controller = PaletteController(model: model, panel: panel, transcriber: { FakeTranscriber() })
  var fronted: [String] = []
  panel.onFront = { fronted.append(controller.presentation.command ?? "root") }
  model.navigator.surface = controller
  let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL), targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
  controller.showOnLaunch(event)
  #expect(!controller.isShown && fronted.isEmpty)
  controller.showOnLaunch(event, opening: [URL(string: "wicket://mover?input=x")!])
  #expect(controller.isShown && !fronted.isEmpty && fronted.allSatisfy { $0 == "extension:mover" })
  await model.navigator.settled()
  controller.hide()
  await model.finish()
}

/// A repeat is the same binding while its request still runs: another extension's item with an equal
/// address runs, and so does the same hotkey once typing replaced its request.
@MainActor @Test func onlyTheSameHotkeyWhileItsRequestRunsIsIgnored() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["one", "two"] {
    _ = try extensionFolder(
      root, name: name,
      script: """
        echo "$(cat)" >> log.jsonl
        while [ ! -e "\(root.path)/release" ]; do sleep 0.01; done
        echo '{"items":[]}'
        """,
      fields: ["name": name, "items": [["id": "go", "title": "Go", "actions": [["type": "run"]]]]])
  }
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  func sent(_ name: String) -> Int {
    (try? requests(in: root.appending(path: "extensions/" + name)).count) ?? 0
  }
  model.press(HotkeyTarget(target: "extension:one", item: "go"))
  #expect(await eventually { sent("one") == 1 })
  let two = HotkeyTarget(target: "extension:two", item: "go")
  model.press(two)
  #expect(await eventually { sent("two") == 1 })
  model.press(two)
  try await Task.sleep(for: .milliseconds(100))
  #expect(sent("two") == 1)
  // Followed like a link, the command shows once its deadline passes; typing there sends a new request.
  model.navigator.passDeadline()
  #expect(model.navigator.command?.id == "extension:two")
  model.navigator.input = "x"
  #expect(await eventually { sent("two") == 2 })
  model.press(two)
  #expect(await eventually { sent("two") == 3 })
  try Data().write(to: root.appending(path: "release"))
  await model.finish()
}

/// A visible hotkey's run is an ordinary request of the open command: leaving it stops it, so a late
/// result never replaces the screen the user went to or ends an agent's turn.
@MainActor @Test func aVisibleHotkeysLateResultNeverReplacesANewerScreen() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  let show = HotkeyTarget(target: "extension:mover", item: "show")
  // Escape back to the root.
  model.press(show)
  #expect(await eventually { (try? runs(root).count) == 1 })
  #expect(model.navigator.escape())
  await model.navigator.settled()
  #expect(model.navigator.command == nil)
  // A question asked meanwhile.
  model.press(show)
  #expect(await eventually { (try? runs(root).count) == 2 })
  model.navigator.send("why")
  #expect(await eventually { fake.running })
  try Data().write(to: root.appending(path: "release"))
  try await Task.sleep(for: .milliseconds(100))
  await model.navigator.settled()
  #expect(model.agent.active && model.agent.busy && model.navigator.agentScreen != nil)
  #expect(model.navigator.command?.shown.view.items.isEmpty == true)
  fake.end()
  await model.finish()
}

@MainActor @Test func rowsWithAnAddressOfferAHotkeyAndShowIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let left = HotkeyTarget(target: "extension:mover", item: "left")
  model.store.bind(try Shortcut("ctrl+option+left"), to: left)
  model.navigator.input = "left"
  await model.navigator.settled()
  let row = try #require(model.navigator.results.first { $0.row.id == "item:left" })
  #expect(model.navigator.hotkeyTarget(of: row) == left && model.navigator.hotkey(of: row)?.symbols == "⌃⌥←")
  model.navigator.input = "mover"
  await model.navigator.settled()
  let command = try #require(model.navigator.results.first { $0.row.id == "command" })
  #expect(model.navigator.hotkeyTarget(of: command) == HotkeyTarget(target: "extension:mover"))
  #expect(model.navigator.hotkey(of: command) == nil)
  model.navigator.input = "settings"
  await model.navigator.settled()
  let settings = try #require(model.navigator.results.first { $0.provider == "settings" })
  #expect(model.navigator.hotkeyTarget(of: settings) == HotkeyTarget(target: "settings"))
  // Inside the command its items carry their own ids.
  model.navigator.go(Address(extensionName: "mover"))
  #expect(
    await eventually {
      model.navigator.command?.id == "extension:mover" && model.navigator.command?.busy == false
    })
  let inside = try #require(model.navigator.results.first { $0.row.id == "left" })
  #expect(model.navigator.hotkey(of: inside)?.symbols == "⌃⌥←")
  // An app, a file or a fallback has no address of its own.
  #expect(
    model.navigator.hotkeyTarget(of: Result(provider: "apps", row: Row(id: "x", title: "X", actions: [])))
      == nil)
}

@MainActor @Test func setHotkeyRecordsWithEveryHotkeyPausedUntilThePanelHides() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  var pauses: [Bool] = []
  let controller = PaletteController(model: model, panel: RoutingPanel(), pauseHotkeys: { pauses.append($0) })
  controller.show(orderFront: false, listen: false)
  model.navigator.input = "left"
  await model.navigator.settled()
  let row = try #require(model.navigator.results.first { $0.row.id == "item:left" })
  let set = try #require(model.navigator.actions(of: row).last)
  // Recording is the panel's: the navigator leaves it to the panel.
  #expect(set.label == "Set Hotkey…" && !model.navigator.activate(set, from: row))
  model.navigator.select(row.id)
  controller.run(set)
  #expect(controller.recorder.isRecording && controller.recordsHotkey(of: row) && pauses == [true])
  controller.hide()
  #expect(!controller.recorder.isRecording && controller.recorder.target == nil && pauses == [true, false])
  // A row without an address offers no hotkey.
  let app = Result(provider: "apps", row: Row(id: "x", title: "X", actions: [.copy("x")]))
  #expect(model.navigator.actions(of: app) == [.copy("x")])
}

/// A rejected recording changed no hotkey, so the footer says why only until the panel hides or the next
/// recording starts; what registration reports stays.
@MainActor @Test func aRejectedRecordingLastsUntilThePanelHidesOrTheNextRecording() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, _) = try await windowLike(root)
  let controller = PaletteController(model: model, panel: RoutingPanel())
  let left = HotkeyTarget(target: "extension:mover", item: "left")
  model.store.applyBinding = { _, _ in "in use" }
  controller.show(orderFront: false, listen: false)
  model.store.bind(try Shortcut("ctrl+option+h"), to: left)
  #expect(model.problem == "in use")
  controller.hide()
  #expect(model.problem == nil)
  controller.show(orderFront: false, listen: false)
  model.store.bind(try Shortcut("ctrl+option+h"), to: left)
  controller.recorder.record(left, in: controller.panel, store: model.store, pausing: { _ in })
  #expect(model.problem == nil)
  controller.recorder.stop()
  model.store.bindingProblem = "not registered"
  controller.hide()
  #expect(model.problem == "not registered")
  await model.finish()
}
