import AppKit
import SwiftUI
import Testing
import Vision
import WebKit

@testable import WicketApp

// Opt-in panel captures. Run with WICKET_CAPTURE_DIR set to a folder:
//
//   WICKET_CAPTURE_DIR=$PWD/docs/screens swift test --filter panelCapture
//
// Set WICKET_CAPTURE_STATES to a comma-separated list to capture just those states.
//
// Two runs draw identical pixels when `SWIFT_DETERMINISTIC_HASHING=1` is set too (an extension's report
// prints its request with unordered keys), so a refactor can be checked by comparing them.
//
// Every state is drawn offscreen in light and dark: no window is ordered front or made key, no
// event is posted, no real agent, microphone or global shortcut is used, and nothing outside
// scratch folders and the capture folder is touched. Surfaces show only their backing, because glass
// does not render offscreen. The captures prove layout and foreground, not glass, focus or shadows. Each
// capture is read back with text recognition and must show the content its state promises.
// Without the variable the capture test is skipped and `scenariosSetUpTheirState` still checks
// the setup of every state without drawing anything. Text recognition has hung once inside
// `VNImageRequestHandler.perform`; if a run stops making progress, kill it and rerun.

private let captureDirectory = ProcessInfo.processInfo.environment["WICKET_CAPTURE_DIR"]
private let captureStates = ProcessInfo.processInfo.environment["WICKET_CAPTURE_STATES"]?
  .split(separator: ",").map(String.init)

private let states =
  [
    "empty", "apps", "actions", "math", "ask", "answer", "listening",
    "conversation-multi", "conversation-reopen", "conversation-long", "conversation-long-expanded",
    "working", "working-text", "permission-routine", "permission-high",
    "answer-small", "answer-large", "answer-larger", "apps-larger", "permission-routine-larger",
    "extension-pattern", "extension-list", "extension-quicklinks-empty", "extension-detail", "extension-both",
    "weather-keyword", "weather-root", "weather-page", "weather-default",
    "extension-targets", "extension-detail-larger", "asking", "asking-extension",
    "extension-error", "fields-empty", "fields-filled", "fields-command", "fields-open",
    "fields-long", "fields-three", "history", "history-reopened", "clipboard", "clipboard-image",
    "settings-general", "settings-voice", "settings-agent", "settings-extensions", "settings-window",
    "settings-extension-shadow", "settings-extension-local",
    "settings-quicklinks", "settings-quicklinks-add", "settings-quicklinks-edit",
    "settings-quicklinks-search", "settings-window-add", "settings-window-invalid", "settings-error",
    "settings-conflict",
  ] + transitions

/// Moments in the middle of a switch, recorded before the screens move to their own owners: each is
/// drawn at its checkpoint, not once everything settled, so a broken transition cannot pass.
private let transitions = [
  "arrival-root-held", "arrival-running", "arrival-page-ready", "arrival-back-held", "arrival-typed",
  "arrival-dictated", "extension-actions", "answer-actions", "extension-nested-detail",
  "extension-actions-back", "answer-actions-back", "asking-running-command", "asking-running-back",
  "history-back", "conversation-back-command", "hotkey-command-error", "hotkey-binding",
]

/// What text recognition must find, so a blank or broken panel fails.
private func expectedText(_ name: String) -> [String] {
  if let text = transitionText[name] { return text }
  if name == "weather-keyword" { return ["weather", "Ask agent"] }
  if name == "weather-root" { return ["Berlin", "overcast", "Ask agent"] }
  if name == "weather-page" || name == "weather-default" {
    return ["Overcast", "Berlin, Germany", "Next hours", "Next days", "Wind"]
  }
  if name.contains("settings-general") { return ["Text size", "Medium", "Open Wicket", "Launch at login"] }
  if name.contains("settings-extensions") {
    return ["Built in", "Clipboard", "Weather", "Windows", "Finds the apps on this Mac by name"]
  }
  if name == "settings-window" {
    return ["Gap", "Saved Moves", "Coding layout", "Windows"]
  }
  if name == "settings-extension-shadow" {
    return [
      "A local copy replaces the built-in version", "Use Built-in", "Ask Agent to Merge", "Show in Finder",
      "Default city", "Temperature unit", "Hotkeys",
    ]
  }
  if name == "settings-extension-local" {
    return ["Site Status", "Settings", "Endpoint", "Hotkeys", "Show in Finder", "Move to Trash"]
  }
  if name == "settings-quicklinks" {
    return ["Quicklinks", "Bookmarks", "Wicket Docs", "Site Searches", "Search YouTube"]
  }
  if name == "settings-quicklinks-add" {
    return ["Add Bookmark", "Title", "URL", "Keyword", "Cancel", "Save"]
  }
  if name == "settings-quicklinks-edit" {
    return ["Edit Bookmark", "Wicket Docs", "wicket.app", "Cancel", "Save"]
  }
  if name == "settings-quicklinks-search" {
    return ["Add Site Search", "Put {query} where the search text goes", "Save"]
  }
  if name == "settings-window-add" {
    return [
      "Add Window Move", "Title", "Anchor", "Center", "Width", "50", "Height", "100", "Keyword", "Save",
    ]
  }
  if name == "settings-window-invalid" {
    return ["Add Window Move", "Coding", "Width", "Enter a number from 10 to 100", "Keyword", "Save"]
  }
  if name.contains("settings-") { return [] }
  if name == "extension-quicklinks-empty" { return ["Quicklinks", "Add a Quicklink"] }
  if name.contains("clipboard-image") {
    // Text recognition reads × as x, now and then.
    return ["Clipboard", "Image 1200", "Dimensions", "File size", "Copied", "50m ago"]
  }
  if name.contains("clipboard") {
    return ["Clipboard", "func greet", "Hello", "Copied", "Lines", "Characters", "Paste"]
  }
  if name.contains("permission-high") {
    return ["Allow Claude to delete files", "Deletes", "Show details", "Allow deletion"]
  }
  if name.contains("permission-routine") {
    return [
      "Allow Claude to edit files", "Update the weather extension", "2 files", "Don't allow", "Allow once",
    ]
  }
  if name.contains("history-reopened") {
    return ["And for the whole week", "Build something useful", "Continuing conversation"]
  }
  if name.contains("history") {
    return ["Agent History", "How is the launch going", "Claude", "What should I build next", "ChatGPT"]
  }
  if name.contains("conversation-reopen") {
    return ["Could this work offline", "Continuing conversation", "End conversation"]
  }
  if name.contains("conversation-long") {
    return ["Ask a follow-up", "How can I improve", "Show", "Build something useful"]
  }
  if name.contains("conversation") {
    return ["Ask a follow-up", "What should I build next", "Build something useful"]
  }
  if name.contains("working-text") {
    return ["What should I build next", "Build something useful", "Cancel"]
  }
  if name.contains("working") { return ["What should I build next", "Thinking", "Cancel"] }
  if name.contains("listening") { return ["rainbows", "Ask agent", "Listening", "Ask", "Close"] }
  if name.contains("asking-extension") {
    return ["Ask about Extension report", "Claude will see what Extension report shows", "Ask", "Esc Back"]
  }
  if name.contains("asking") { return ["Ask Claude", "Type a question for Claude", "Esc Back"] }
  if name.contains("extension-detail") {
    return [
      "Extension report", "A useful extension", "42", "Local extension", "One JSON view", "Actions",
      "Ask about Extension report",
    ]
  }
  if name.contains("extension-both") {
    return [
      "Extension report", "A useful extension", "Local extension", "Hourly forecast", "Weekly forecast",
      "Actions",
    ]
  }
  if name.contains("actions") { return ["Actions for Settings", "Open", "Set Hotkey", "esc Back"] }
  if name.contains("extension-targets") { return ["Berlin this week", "Wed", "Hourly forecast", "Run"] }
  if name.contains("extension-error") {
    return ["Extension report", "Invalid extension view", "REPAIR", "Ask agent"]
  }
  if name.contains("fields-empty") { return ["caff", "Caffeinate", "hours", "minutes"] }
  if name.contains("fields-filled") { return ["caff", "Caffeinate", "12", "30"] }
  if name.contains("fields-open") { return ["Caffeinate", "hours", "minutes"] }
  if name.contains("fields-long") { return ["hours", "minutes", "Awake"] }
  if name.contains("fields-three") { return ["caff", "hours", "minutes", "seconds"] }
  if name.contains("fields-command") { return ["Caffeinate", "12", "30", "Awake for 12 h 30 min"] }
  if name.contains("extension-pattern") {
    return ["6\(ProviderRequest.NumberMarks.current.decimal)21", "Copy value", "Ask agent"]
  }
  if name.contains("extension-list") { return ["Quicklinks", "Search YouTube", "Search Wikipedia"] }
  if name.contains("answer") {
    return ["Ask a follow-up", "A good start", "Extensions", "Ready for a follow-up"]
  }
  if name.contains("math") { return ["200", "28", "Ask agent"] }
  if name.contains("ask") { return ["rainbows", "Ask agent"] }
  if name.contains("empty") { return ["Search", "Calculator", "Ask agent", "Open", "Close"] }
  return ["cal", "Calculator", "Calendar", "Ask agent", "Open", "Close"]
}

private let transitionText = [
  "arrival-root-held": ["Calculator", "Calendar", "Mover", "Notes", "esc Close"],
  "arrival-running": ["Slow list", "Running"],
  "arrival-page-ready": ["Weekly report", "Three releases shipped", "Release notes", "Owner"],
  "arrival-back-held": ["Notes", "Groceries", "Ideas"],
  "arrival-typed": ["fin", "Running", "Slow list"],
  "arrival-dictated": ["Finished yet", "Running", "Listening"],
  "extension-actions": ["Actions for Weekly report", "Copy", "Refresh", "esc Back"],
  "answer-actions": ["Actions for Swift Testing", "Open", "esc Back"],
  "extension-nested-detail": ["Known issues", "Two open problems remain", "Esc Back"],
  "extension-actions-back": ["Weekly report", "Release notes", "Owner"],
  "answer-actions-back": ["A good start", "Ask a follow-up", "Open", "End conversation"],
  "asking-running-command": ["Ask about Slow list", "Esc Back"],
  "asking-running-back": ["Slow list", "Running"],
  "history-back": ["Agent History", "How is the launch going", "What should I build next"],
  "conversation-back-command": ["Notes", "Groceries", "Ideas"],
  "hotkey-command-error": ["Mover", "exited with status 1", "REPAIR: no window to move"],
  "hotkey-binding": ["Slow list", "Left half", "Mover"],
]

private let launchAnswer =
  "# A good start\nTwelve extensions, all local\n<columns><tile label=\"Extensions\" icon=\"puzzlepiece.extension\" title=\"12\" subtitle=\"3 new this week\"/><tile label=\"Response\" icon=\"bolt\" title=\"42 ms\"/></columns>\n<card icon=\"exclamationmark.triangle\">\n## Restart once\nAfter updating, quit and reopen Wicket.\n</card>\n<row label=\"Owner\" value=\"You\"/>\n<row label=\"Next\" value=\"Build something useful\"/>\n<progress label=\"Disk used\" value=\"420 of 600 GB\" percent=\"70\"/>\n<row label=\"14:30\" title=\"Train departs\" subtitle=\"Platform 6\"/>\n<row label=\"16:05\" title=\"Arrives in Berlin\"/>\n<badge label=\"Healthy\" tone=\"positive\"/> <badge label=\"v2.4\"/>\n<row title=\"Swift Testing\" subtitle=\"Apple guide\" open=\"https://developer.apple.com/documentation/testing\"/>\n<row title=\"Copy the summary\" copy=\"A good start\"/>\n<row title=\"How do I add an extension?\" ask=\"How do I add an extension?\"/>"
private let nextAnswer =
  "## Build something useful\nStart with a small weather extension. Put the current temperature in its result row, with the full forecast one step away.\n\nKeep it **local**, quick and easy to change."

/// A picture to copy: a sky, a sun and a hill, 1200×800 pixels.
@MainActor private func captureImage() -> Data {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGradient(starting: .systemTeal, ending: .systemIndigo)!.draw(
    in: NSRect(x: 0, y: 0, width: 1200, height: 800), angle: 90)
  NSColor.systemYellow.setFill()
  NSBezierPath(ovalIn: NSRect(x: 780, y: 470, width: 200, height: 200)).fill()
  NSColor.systemGreen.setFill()
  NSBezierPath(ovalIn: NSRect(x: -300, y: -900, width: 1800, height: 1300)).fill()
  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .png, properties: [:])!
}

/// A panel that can never become key, so nothing here can take focus even by accident.
@MainActor private final class CapturePanel: PalettePanel {
  override var canBecomeKey: Bool { false }
}

@MainActor private final class FixedApps: Provider {
  let id = "apps"
  /// Answers only when cancelled, so a switch back to the root waits for its list.
  var held = false
  private let index = SearchIndex(
    ["Calendar", "Calculator", "Chess"].map { name in
      Row(
        id: name.lowercased(), title: name, subtitle: "Application",
        actions: [.open(URL(fileURLWithPath: "/System/Applications/" + name + ".app"))])
    })
  func view(for request: ProviderRequest) async -> ProviderView {
    if held { try? await Task.sleep(for: .seconds(60)) }
    return .init(items: index.matches(request.input))
  }
}

/// This run's own scratch storage: runs in other clones at the same time never share a folder.
private let captureRun = FileManager.default.temporaryDirectory.appending(
  path: "wicket-capture-" + UUID().uuidString)

/// A scratch folder of this run, by name.
private func captureFolder(_ name: String) throws -> URL {
  let folder = captureRun.appending(path: name)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

/// Extensions whose failure report a capture draws (`extension-error`, `hotkey-command-error`): the
/// report shows the extension's folder, so these are the model's bundled ones at a path that is the same
/// in every run. Every run writes the same files and none removes them, so runs at the same time cannot
/// break each other.
private func reportedExtensions() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: "wicket-capture-fixtures")
  func install(_ id: String, _ manifest: [String: Any], program: String, file: String = "main.sh") throws {
    let folder = root.appending(path: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(
      to: folder.appending(path: "wicket.json"), options: .atomic)
    try Data(program.utf8).write(to: folder.appending(path: file), options: .atomic)
  }
  try install(
    "demo",
    [
      "contract": 2, "name": "Extension report", "keyword": "demo",
      "command": ["/usr/bin/python3", "main.py"],
      "icon": "doc.text",
    ],
    program:
      "import json,sys; json.load(sys.stdin); sys.stderr.write('REPAIR: missing closing brace in main.py\\n'); print('{broken')",
    file: "main.py")
  try install(
    "mover",
    [
      "contract": 2, "name": "Mover", "keyword": "mover", "icon": "macwindow",
      "command": ["/bin/sh", "main.sh"],
      "items": [
        [
          "id": "left", "title": "Left half",
          "actions": [["type": "run", "action": "left", "hidden": true]],
        ]
      ],
    ], program: Scenario.moverProgram)
  return root
}

/// A `claude` on PATH that is never run: Agent settings show it installed on any Mac.
private let installedAgent: Void = {
  let bin = captureRun.appending(path: "bin")
  try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let claude = bin.appending(path: "claude")
  FileManager.default.createFile(
    atPath: claude.path, contents: Data("#!/bin/sh\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
  setenv("PATH", bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
}()

/// One state, fully set up and ready to draw. The view lives in a window that is never shown.
@MainActor private final class Scenario {
  let model: LauncherModel
  let controller: PaletteController?
  let view: NSView
  let folder: URL
  private let window: NSWindow?
  private var keep: [AnyObject] = []
  init(model: LauncherModel, controller: PaletteController?, view: NSView, window: NSWindow?, folder: URL) {
    self.model = model
    self.controller = controller
    self.view = view
    self.window = window
    self.folder = folder
  }
  func finish() async {
    if let controller { await controller.finish() } else { await model.finish() }
    window?.close()
    try? FileManager.default.removeItem(at: folder)
  }

  private static func textSize(_ state: String) -> (name: String, size: Configuration.TextSize) {
    for (suffix, size) in [
      ("-larger", Configuration.TextSize.larger), ("-large", .large), ("-small", .small),
    ] where state.hasSuffix(suffix) {
      return (String(state.dropLast(suffix.count)), size)
    }
    return (state, .medium)
  }

  /// `folder` names the scratch folder, so paths a capture draws (an extension's report) repeat; nil is a
  /// unique one.
  static func make(
    _ state: String, dark: Bool, folder name: String? = nil,
    turn: (question: String, reply: String) = ("How is the launch going?", launchAnswer)
  ) async throws -> Scenario {
    _ = NSApplication.shared
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let folder = try name.map(captureFolder) ?? scratch()
    try AnswerRenderer.installFiles(in: folder)
    if state.hasPrefix("settings-") {
      return try await settings(state, folder: folder, appearance: appearance)
    }

    let (name, size) = textSize(state)
    let transcriber = FakeTranscriber()
    let runs = AgentHistory(url: folder.appending(path: "agent-history.json"))
    let clipboard =
      name.hasPrefix("clipboard")
      ? ClipboardHistory(
        url: folder.appending(path: "private/clipboard-history.json"), pasteboard: FakePasteboard(),
        interval: nil) : nil
    let apps = FixedApps()
    let model = LauncherModel(
      apps: apps, clipboard: clipboard, agentHistory: runs,
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
      bundled: ["extension-error", "hotkey-command-error"].contains(name)
        ? try reportedExtensions() : bundledExtensions)
    model.store.update {
      $0.voice.enabled = name == "listening" || name == "arrival-dictated"
      $0.textSize = size
      $0.agent.streamAnswers = name == "working-text"
    }
    let panel = CapturePanel()
    panel.appearance = appearance
    let controller = PaletteController(
      model: model, drawsGlass: false, panel: panel, transcriber: { transcriber })
    let scenario = Scenario(
      model: model, controller: controller, view: panel.contentView!, window: nil, folder: folder)
    scenario.keep.append(transcriber)
    scenario.keep.append(apps)

    if name.hasPrefix("answer") || (name.hasPrefix("conversation") && !transitions.contains(name)) {
      try await finishTurn(model, turn.question, turn.reply)
    }
    if transitions.contains(name) {
      try await transition(name, scenario, apps: apps, transcriber: transcriber, runs: runs)
      return scenario
    }
    switch name {
    case "apps": model.navigator.input = "cal"
    case "math":
      await model.extensions.reload()
      model.navigator.input = "200*10%+2^3"
      await model.navigator.settled()
    case "weather-keyword", "weather-root", "weather-page", "weather-default":
      let runner = ExtensionRunner(dataDirectory: folder.appending(path: "extension-data"))
      try await seedRecordedWeather(in: runner.dataDirectory(for: "extension:weather"))
      await model.extensions.reload()
      if name == "weather-default" {
        model.store.update { $0.extensions["weather"] = .object("defaultCity", .string("Berlin")) }
        model.navigator.go(Address(id: "extension:weather", link: true))
        await model.navigator.settled()
      } else {
        model.navigator.input = name == "weather-keyword" ? "weather " : "weather Berlin"
        await model.navigator.settled()
        try #require(model.navigator.selected?.row.id == (name == "weather-keyword" ? "command" : "weather"))
        if name == "weather-page" {
          try #require(model.activateReturn())
          await model.navigator.settled()
        }
      }
    case "ask": model.navigator.input = "How do rainbows form?"
    case "listening":
      controller.input.arm()
      transcriber.feeds[0].yield(.ready)
      transcriber.feeds[0].yield(.transcript("How do rainbows form?"))
      #expect(await eventually { model.navigator.input == "How do rainbows form?" })
    case "conversation-reopen":
      model.navigator.input = "Could this work offline?"
      model.navigator.dismiss()
      model.reopen()
    case _ where name.hasPrefix("conversation") || name.hasPrefix("permission") || name.hasPrefix("working"):
      let agent = FakeAgent()
      scenario.keep.append(agent)
      model.agent.connect = { _, _, _ in agent }
      let question =
        name.hasPrefix("conversation-long")
        ? String(
          repeating: "How can I improve this launcher while keeping the experience calm and native? ",
          count: 5)
        : (name.hasPrefix("permission") ? "Update the weather extension" : "What should I build next?")
      model.navigator.send(question)
      #expect(await eventually { agent.running })
      if name.hasPrefix("permission") {
        agent.onEvent(.permission(permissionRequest(high: name == "permission-high", folder: folder)))
        #expect(await eventually { !model.agent.permissions.isEmpty })
      } else if name == "working-text" {
        agent.text(nextAnswer)
        #expect(await eventually { !model.agent.answer.isEmpty })
      } else if name != "working" {
        agent.text(nextAnswer)
        agent.end()
        #expect(await eventually { !model.agent.busy })
      }
      if name == "conversation-long-expanded" { model.navigator.toggleQuestion() }
    case "clipboard", "clipboard-image":
      let clips = try #require(clipboard)
      model.store.update { $0.providers = [.init("clipboard")] }
      let minute: TimeInterval = 60
      await clips.capture(image: captureImage(), now: Date() - 50 * minute)
      clips.capture("https://wicket.app/docs/extensions", now: Date() - 20 * minute)
      clips.capture("Launch review moved to 15:00, room 2", now: Date() - 9 * minute)
      clips.capture(
        "func greet(_ name: String) -> String {\n  // Say hello.\n  \"Hello, \\(name)!\"\n}",
        now: Date() - 2 * minute)
      model.navigator.go(Address(extensionName: "clipboard"))
      if name == "clipboard-image" { model.navigator.move(3) }
    case "actions":
      model.navigator.input = "settings"
      await model.navigator.settled()
      model.navigator.toggleActions()
    case _ where name.hasPrefix("extension-"): try await configureExtension(name, model)
    case "asking": model.navigator.askAgent()
    case "asking-extension":
      try await configureExtension("extension-detail", model)
      model.navigator.askAgent()
    case _ where name.hasPrefix("fields-"): try await configureFields(name, model)
    case "history", "history-reopened":
      let hour: TimeInterval = 3600
      runs.save(
        .init(
          id: "older", agent: .codex, session: "t", used: Date().addingTimeInterval(-26 * hour), source: nil,
          turns: [.init(question: "What should I build next?", answer: nextAnswer)]))
      runs.save(
        .init(
          id: "newer", agent: .claude, session: "s", used: Date().addingTimeInterval(-2 * hour),
          source: nil,
          turns: [
            .init(question: "How is the launch going?", answer: launchAnswer),
            .init(question: "And for the whole week?", answer: nextAnswer),
          ]))
      model.navigator.go(Address(extensionName: "history"))
      await model.navigator.settled()
      if name == "history-reopened" { model.activateReturn() }
    default: break
    }
    controller.show(orderFront: false, listen: false)
    await model.navigator.settled()
    return scenario
  }

  /// Sets a transition up from the panel as it is shown, and stops at its checkpoint. Its work may still
  /// be running, held by an extension that never answers or apps that answer only when cancelled.
  private static func transition(
    _ name: String, _ scenario: Scenario, apps: FixedApps, transcriber: FakeTranscriber, runs: AgentHistory
  ) async throws {
    let model = scenario.model
    let controller = try #require(scenario.controller)
    // The hotkey's failing program is in `reportedExtensions`, as the model's bundled one.
    try installTransitionExtensions(model.agent.folder, mover: name != "hotkey-command-error")
    model.extensions.onCatalogChange = nil
    await model.extensions.reload()
    controller.show(orderFront: false, listen: false)
    await model.navigator.settled()
    // Held: the switch waits for content that does not come while the capture is drawn.
    model.navigator.arrivalDeadline = .seconds(60)
    // A running command is drawn as it looks once its busy state shows.
    model.navigator.busyDelay = .zero
    switch name {
    case "arrival-root-held": model.navigator.go(Address(id: "slow"), submitted: true)
    case "arrival-running", "asking-running-command", "asking-running-back":
      model.navigator.arrivalDeadline = .milliseconds(1)
      model.navigator.go(Address(id: "slow"), submitted: true)
      #expect(await eventually { model.navigator.command?.busy == true })
      if name != "arrival-running" { model.navigator.askAgent() }
      if name == "asking-running-back" { #expect(model.navigator.escape()) }
    case "arrival-page-ready", "extension-actions", "extension-nested-detail", "extension-actions-back":
      model.navigator.go(Address(id: "report"), submitted: true)
      await model.navigator.settled()
      await controller.renderer.settled()
      switch name {
      case "extension-actions": model.navigator.toggleActions()
      case "extension-nested-detail":
        // Release notes, then Known issues inside its detail.
        model.navigator.move(1)
        model.activateReturn()
        model.navigator.move(1)
        model.activateReturn()
      case "extension-actions-back":
        model.navigator.move(1)
        model.navigator.toggleActions()
        #expect(model.navigator.escape())
      default: break
      }
    case "arrival-back-held":
      model.navigator.go(Address(id: "notes"), submitted: true)
      apps.held = true
      #expect(model.navigator.escape())
    case "arrival-typed":
      model.navigator.go(Address(id: "slow"), submitted: true)
      model.navigator.editInput("fin")
    case "arrival-dictated":
      let input = try #require(scenario.controller?.input)
      input.arm()
      transcriber.feeds[0].yield(.ready)
      #expect(await eventually { input.voice?.state == .listening })
      model.navigator.go(Address(id: "slow"), submitted: true)
      transcriber.feeds[0].yield(.transcript("Finished yet?"))
      #expect(await eventually { model.navigator.command != nil })
    case "answer-actions", "answer-actions-back":
      model.navigator.move(1)
      model.navigator.toggleActions()
      if name == "answer-actions-back" { #expect(model.navigator.escape()) }
    case "history-back":
      runs.save(
        .init(
          id: "older", agent: .codex, session: "t", used: Date().addingTimeInterval(-26 * 3600), source: nil,
          turns: [.init(question: "What should I build next?", answer: nextAnswer)]))
      runs.save(
        .init(
          id: "newer", agent: .claude, session: "s", used: Date().addingTimeInterval(-2 * 3600), source: nil,
          turns: [.init(question: "How is the launch going?", answer: launchAnswer)]))
      model.navigator.go(Address(extensionName: "history"))
      model.activateReturn()
      #expect(model.agent.continuing && model.navigator.escape())
      await model.navigator.settled()
    case "conversation-back-command":
      let agent = FakeAgent()
      scenario.keep.append(agent)
      model.agent.connect = { _, _, _ in agent }
      model.navigator.go(Address(id: "notes"), submitted: true)
      model.navigator.editInput("Which note is oldest?")
      model.navigator.askAgent()
      #expect(await eventually { agent.running })
      agent.text(nextAnswer)
      agent.end()
      #expect(await eventually { !model.agent.busy })
      #expect(model.navigator.escape())
      await model.navigator.settled()
    case "hotkey-command-error":
      controller.hide()
      let surface = RecordingSurface(wrapping: controller)
      surface.showing = { controller.show(orderFront: false, listen: false, arriving: $0) }
      scenario.keep.append(surface)
      model.navigator.surface = surface
      model.press(HotkeyTarget(target: "extension:mover", item: "left"))
      await model.navigator.settled()
    case "hotkey-binding":
      model.store.bind(try Shortcut("ctrl+option+s"), to: HotkeyTarget(target: "extension:slow"))
      model.store.bind(
        try Shortcut("ctrl+option+left"), to: HotkeyTarget(target: "extension:mover", item: "left"))
      model.navigator.input = "l"
      await model.navigator.settled()
    default: Issue.record("No transition named \(name)")
    }
    if ["arrival-running", "asking-running-back", "arrival-typed", "arrival-dictated"].contains(name) {
      #expect(await eventually { model.navigator.showsBusy })
    }
  }

  /// The commands the transitions switch between: a list that answers only once released (never, in a
  /// capture), a page with a nested detail and actions, items from the manifest, and a hotkey's program
  /// that fails.
  private static func installTransitionExtensions(_ folder: URL, mover: Bool) throws {
    func install(_ id: String, _ manifest: [String: Any], script: String? = nil, view: ProviderView? = nil)
      throws
    {
      let extensionFolder = folder.appending(path: "extensions/" + id)
      try FileManager.default.createDirectory(at: extensionFolder, withIntermediateDirectories: true)
      var manifest = manifest
      if script != nil || view != nil {
        manifest["contract"] = 2
        manifest["command"] = ["/bin/sh", "main.sh"]
      }
      try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(
        to: extensionFolder.appending(path: "wicket.json"))
      if let view { try JSONEncoder().encode(view).write(to: extensionFolder.appending(path: "view.json")) }
      let program = script ?? "cat >/dev/null\ncat view.json"
      try Data(program.utf8).write(to: extensionFolder.appending(path: "main.sh"))
    }
    try install(
      "slow", ["name": "Slow list", "keyword": "slow", "icon": "hourglass"],
      script: """
        cat >/dev/null
        while [ ! -e release ]; do sleep 0.02; done
        printf '%s' '{"items":[{"id":"done","title":"Finished","actions":[]}]}'
        """)
    try install(
      "report", ["name": "Weekly report", "keyword": "report", "icon": "doc.text"],
      view: ProviderView(
        body: """
          ## Weekly report
          Three releases shipped, one is waiting for review.
          <row title="Release notes" subtitle="0.4 beta" copy="0.4 beta">
          Two features landed and one fix.
          <row title="Known issues" copy="Two open problems">Two open problems remain before the release.</row>
          </row>
          <row label="Owner" value="You"/>
          """,
        actions: [.copy("3 releases"), .run(Address(action: "refresh"), title: "Refresh")]))
    try install(
      "notes",
      [
        "name": "Notes", "keyword": "notes", "icon": "note.text",
        "items": ["Groceries", "Ideas"].map {
          ["id": $0.lowercased(), "title": $0, "actions": [["type": "copy", "text": $0]]]
        },
      ])
    guard mover else { return }
    try install(
      "mover",
      [
        "name": "Mover", "keyword": "mover", "icon": "macwindow",
        "items": [
          [
            "id": "left", "title": "Left half",
            "actions": [["type": "run", "action": "left", "hidden": true]],
          ]
        ],
      ],
      script: moverProgram)
  }
  nonisolated static let moverProgram = "cat >/dev/null\necho 'REPAIR: no window to move' >&2\nexit 1"

  private static func permissionRequest(high: Bool, folder: URL) -> AgentPermission {
    let paths =
      high
      ? ["/Users/example/Documents/old-weather.json"]
      : [
        folder.appending(path: "extensions/weather/main.py").path,
        folder.appending(path: "extensions/weather/wicket.json").path,
      ]
    return AgentPermission(
      id: .number(1), title: high ? "Delete the old weather data" : "Update the weather extension",
      kind: high ? .delete : .edit, paths: paths,
      raw: .object(
        "command", .string(high ? "rm ~/Documents/old-weather.json" : "Update weather sources and manifest")))
  }

  private static func configureExtension(_ state: String, _ model: LauncherModel) async throws {
    let folder = model.agent.folder
    let host = model.extensions
    try ExtensionHost.installFiles(in: folder)
    host.onCatalogChange = nil
    if state == "extension-targets" {
      // A body whose days run the extension again, then its JSON items as rows; the third day selected.
      let demo = folder.appending(path: "extensions/demo")
      try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: [
        "contract": 2, "name": "Weather", "keyword": "demo", "command": ["/usr/bin/python3", "main.py"],
        "icon": "cloud.sun",
      ]).write(to: demo.appending(path: "wicket.json"))
      let days = zip(
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        ["cloud", "cloud.rain", "cloud.heavyrain", "cloud.sun.rain", "cloud.sun", "sun.max", "sun.max"]
      ).enumerated().map { index, day in
        "<tile label=\"\(day.0)\" icon=\"\(day.1)\" title=\"\(12 - index % 4)° \(5 + index % 3)°\" run=\"view=day&day=\(day.0.lowercased())\"/>"
      }
      let view = ProviderView(
        body: "## Berlin this week\nMild and wet, dry at the weekend.\n<columns>\(days.joined())</columns>",
        items: [
          Row(
            id: "hourly", title: "Hourly forecast", subtitle: "Next 24 hours", icon: "clock",
            actions: [.run(Address(fields: ["view": "hourly"]))]),
          Row(
            id: "radar", title: "Rain radar", subtitle: "Deutscher Wetterdienst", icon: "map",
            actions: [.open(URL(string: "https://www.dwd.de")!, title: "Open radar")]),
        ], actions: [.copy("12°")])
      try JSONEncoder().encode(view).write(to: demo.appending(path: "view.json"))
      try Data("import json,sys; json.load(sys.stdin); sys.stdout.write(open('view.json').read())".utf8)
        .write(
          to: demo.appending(path: "main.py"))
      await host.reload()
      model.navigator.input = "demo"
      await model.navigator.settled()
      _ = model.activateReturn()
      await model.navigator.settled()
      for _ in 0..<3 { model.navigator.move(1) }
    } else if state == "extension-error" {
      // Its extension is in `reportedExtensions`, as the model's bundled one.
      await host.reload()
      model.navigator.input = "demo"
      await model.navigator.settled()
      _ = model.activateReturn()
      await model.navigator.settled()
    } else if ["extension-detail", "extension-both"].contains(state) {
      let demo = folder.appending(path: "extensions/demo")
      try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: [
        "contract": 2, "name": "Extension report", "keyword": "demo",
        "command": ["/usr/bin/python3", "main.py"],
        "icon": "doc.text",
        "fields": [["name": "query", "type": "text", "description": "Search"]],
      ]).write(to: demo.appending(path: "wicket.json"))
      let both = state == "extension-both"
      let view = ProviderView(
        body:
          "## A useful extension\n<tile label=\"Total\" title=\"42\"/>\n<card>Written by a program, displayed by Wicket.</card>\n<row label=\"Source\" value=\"Local extension\"/>\n<row label=\"Format\" value=\"One JSON view\"/>",
        items: both
          ? [
            Row(
              id: "hourly", title: "Hourly forecast", subtitle: "Next 24 hours", icon: "clock",
              actions: [.run(Address(fields: ["view": "hourly"]), title: "Hourly")]),
            Row(
              id: "weekly", title: "Weekly forecast", subtitle: "Next 7 days", icon: "calendar",
              actions: [.run(Address(fields: ["view": "weekly"]), title: "Weekly")]),
          ] : [],
        actions: [
          .copy("42"), .run(Address(action: "refresh"), title: "Refresh"),
          .agent("Explain this report"),
        ])
      try JSONEncoder().encode(view).write(to: demo.appending(path: "view.json"))
      try Data("import json,sys; json.load(sys.stdin); sys.stdout.write(open('view.json').read())".utf8)
        .write(to: demo.appending(path: "main.py"))
      await host.reload()
      model.navigator.input = "demo"
      await model.navigator.settled()
      _ = model.activateReturn()
      await model.navigator.settled()
    } else {
      if state == "extension-list" {
        try writeQuicklinks(in: model.agent.folder)
        model.store.load()
      }
      await host.reload()
      switch state {
      case "extension-list", "extension-quicklinks-empty":
        model.navigator.go(Address(id: "extension:links-search", link: true))
      default: model.navigator.input = "10 km in mi"
      }
      await model.navigator.settled()
    }
  }

  /// A command with two declared fields (three in `fields-three`), as the root row with its slots
  /// and as the open command: filled, empty, and with a long input pushing the slots to the end.
  private static func configureFields(_ state: String, _ model: LauncherModel) async throws {
    let folder = model.agent.folder.appending(path: "extensions/caffeinate")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "contract": 2, "name": "Caffeinate", "command": ["/usr/bin/python3", "main.py"],
      "icon": "cup.and.saucer",
      "fields": [
        ["name": "hours", "type": "number", "description": "Hours", "placeholder": "hours"],
        ["name": "minutes", "type": "number", "description": "Minutes"],
      ]
        + (state == "fields-three"
          ? [["name": "seconds", "type": "number", "description": "Seconds"]] : [])
        ,
    ]).write(to: folder.appending(path: "wicket.json"))
    let code = """
      import json,sys; a=json.load(sys.stdin)['fields']
      print(json.dumps({'items':[{'id':'awake','title':'Awake for %s h %s min' % (a.get('hours','0'), a.get('minutes','0')),'actions':[]}]}))
      """
    try Data(code.utf8).write(to: folder.appending(path: "main.py"))
    await model.extensions.reload()
    model.navigator.input = "caff"
    await model.navigator.settled()
    if state == "fields-filled" || state == "fields-command" {
      model.navigator.setField("hours", to: "12")
      model.navigator.setField("minutes", to: "30")
    }
    if ["fields-command", "fields-open", "fields-long"].contains(state) {
      _ = model.activateReturn()
      await model.navigator.settled()
    }
    if state == "fields-long" {
      model.navigator.input = "a long note about why the build server should stay awake through the night"
      await model.navigator.settled()
    }
  }

  private static func settings(_ state: String, folder: URL, appearance: NSAppearance?) async throws
    -> Scenario
  {
    try ExtensionHost.installFiles(in: folder)
    let store = ConfigurationStore(url: folder.appending(path: "config.json"))
    var initial = Configuration()
    initial.agent.model = "sonnet"
    if state == "settings-window" {
      initial.hotkeys = [
        .init(
          keys: try Shortcut("ctrl+option+left"),
          target: HotkeyTarget(target: "extension:window", item: "left")),
        .init(
          keys: try Shortcut("ctrl+option+1"),
          target: HotkeyTarget(target: "extension:window", item: "coding", entryList: "moves")),
      ]
      initial.extensions = [
        "window": .object([
          "gap": .string("8"), "moves": .array([.object(codingMove.mapValues(JSONValue.string))]),
        ])
      ]
    }
    if state == "settings-extensions" || state == "settings-extension-shadow" {
      try FileManager.default.copyItem(
        at: bundledExtensions.appending(path: "weather"), to: folder.appending(path: "extensions/weather"))
      initial.providers.append(.init("extension:weather", enabled: false))
    }
    if state == "settings-extension-local" {
      _ = try extensionFolder(
        folder, name: "site-status",
        fields: [
          "name": "Site Status", "description": "Checks whether a website is responding.",
          "settings": [["name": "endpoint", "type": "text", "description": "Endpoint"]],
        ])
    }
    let quicklinks = state.hasPrefix("settings-quicklinks")
    let bookmarks = [
      ["id": "wicket", "title": "Wicket Docs", "url": "https://wicket.app/docs", "keyword": "wd"],
      ["id": "swift", "title": "Swift", "url": "https://swift.org"],
    ]
    if quicklinks {
      initial.extensions["links-search"] = .object([
        "links": .array(bookmarks.map { .object($0.mapValues(JSONValue.string)) }),
        "searches": .array(quicklinkSearches.prefix(1).map { .object($0.mapValues(JSONValue.string)) }),
      ])
      initial.hotkeys = [
        .init(
          keys: try Shortcut("ctrl+option+w"),
          target: HotkeyTarget(
            target: "extension:links-search", item: "wicket", entryList: "links"))
      ]
    }
    try initial.save(at: store.url)
    // Fresh cached models mean the pane never starts a CLI; the closure guards the rest.
    let efforts = ["low", "medium", "high", "xhigh"]
    try AgentDiscovery.save(
      [
        AgentModel(id: "fable", name: "Fable 5.2", efforts: efforts, fast: true),
        AgentModel(id: "opus", name: "Opus 5.5", efforts: efforts, fast: true),
        AgentModel(id: "sonnet", name: "Sonnet 5.5", efforts: efforts),
        AgentModel(id: "haiku", name: "Haiku 5.5", efforts: efforts),
      ],
      agent: .claude, in: folder)
    store.discover = { _ in throw AgentFailure("Captures never start an agent") }
    store.checkSignIn = { _ in .signedIn }
    _ = installedAgent
    let host = ExtensionHost(folder: folder, bundled: bundledExtensions)
    store.start(watching: false)
    _ = host.applySettings(store.configuration.extensions)
    await host.reload()
    if state == "settings-error" {
      try Data("{".utf8).write(to: store.url, options: .atomic)
      store.load()
    }
    if state == "settings-conflict" { store.hotkeyProblem = "⌃K is in use. ⌥Space still opens Wicket." }
    let section =
      ["settings-general", "settings-voice", "settings-agent", "settings-extensions"].firstIndex(of: state)
      ?? (state == "settings-window" || state.hasPrefix("settings-extension-") || quicklinks ? 3 : 0)
    let selected =
      switch state {
      case "settings-window": "extension:window"
      case "settings-extension-shadow": "extension:weather"
      case "settings-extension-local": "extension:site-status"
      default: quicklinks ? "extension:links-search" : "apps"
      }
    let pane = NSHostingView(
      rootView: SettingsPane(
        section: section, store: store, extensions: host,
        clipboard: ClipboardHistory(
          url: folder.appending(path: "clipboard-history.json"),
          pasteboard: NSPasteboard(name: .init(UUID().uuidString)),
          interval: nil),
        runs: AgentHistory(url: folder.appending(path: "agent-history.json")),
        updater: nil, pauseHotkey: { _ in }, selected: selected))
    let view: NSView
    let windowEditor = state == "settings-window-add" || state == "settings-window-invalid"
    if quicklinks && state != "settings-quicklinks" || windowEditor {
      let folder = windowEditor ? "window" : "links-search"
      let name = windowEditor ? "moves" : state == "settings-quicklinks-search" ? "searches" : "links"
      let list = try #require(
        host.commands["extension:" + folder]?.manifest.settings.first { $0.name == name }?.list)
      let editing = state == "settings-quicklinks-edit"
      let values =
        state == "settings-window-invalid" ? ["title": "Coding", "width": "5"] : editing ? bookmarks[0] : [:]
      let draft = SettingsEntryDraft(
        folder: folder, list: list, values: values,
        entryID: editing ? bookmarks[0]["id"] : nil)
      // A native sheet's content has its own surface. Host that same content without presenting a window.
      let editor = NSHostingView(rootView: SettingsEntryEditor(draft: draft, store: store, close: {}))
      editor.frame = NSRect(origin: .zero, size: SettingsEntryEditor.size(for: list))
      view = editor
    } else {
      pane.frame = NSRect(origin: .zero, size: SettingsPane.size)
      view = pane
    }
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = view
    if state == "settings-agent" {
      // The pane checks on appearing; the capture draws only once the check answered.
      store.discoverOptions()
      await store.discovery?.value
      #expect(AgentCLI.installed(.claude) && store.signIn[.claude] == .signedIn)
    }
    let model = LauncherModel.testing(in: folder)
    let scenario = Scenario(model: model, controller: nil, view: view, window: window, folder: folder)
    scenario.keep.append(store)
    scenario.keep.append(host)
    return scenario
  }
}

/// Draws the view offscreen. Web views are drawn from their own snapshots: the composited layer of a
/// web view in a window that is never shown sometimes stays blank however long one waits (whole
/// batches of pages did, now and then), while a snapshot is rendered by WebKit itself.
/// Web views are hidden for the first draw: a page that did paint would otherwise be drawn twice,
/// doubling every translucent color.
@MainActor private func render(_ view: NSView, to url: URL) async throws {
  view.layoutSubtreeIfNeeded()
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    throw ExtensionFailure("No render target")
  }
  func webViews(_ view: NSView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
  }
  // SwiftUI's opacity, as under the action panel, is an ancestor's alpha, which a snapshot ignores.
  func transparent(_ view: NSView?) -> Bool {
    view.map { $0.alphaValue == 0 || transparent($0.superview) } ?? false
  }
  let shown = webViews(view).filter {
    !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && !transparent($0)
  }
  for web in shown { web.isHidden = true }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  for web in shown { web.isHidden = false }
  for web in shown {
    // Only the part a scroll region shows.
    let configuration = WKSnapshotConfiguration()
    configuration.rect = web.visibleRect
    let image = try await web.takeSnapshot(configuration: configuration)
    var frame = web.convert(web.visibleRect, to: view)
    // The bitmap's context is never flipped.
    if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
  }
  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw ExtensionFailure("Could not encode the render as PNG")
  }
  try data.write(to: url)
}

/// The capture is read over a mid grey, a neutral desktop behind the glass: its backing is translucent, and
/// text recognition missed short words over pure black or white.
private func recognizedText(in url: URL) throws -> String {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let context = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw ExtensionFailure("Unreadable capture") }
  let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  context.setFillColor(CGColor(gray: 0.5, alpha: 1))
  context.fill(rect)
  context.draw(image, in: rect)
  guard let flat = context.makeImage() else { throw ExtensionFailure("Unreadable capture") }
  try VNImageRequestHandler(cgImage: flat).perform([request])
  return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

@MainActor
@Test(
  .enabled(if: captureDirectory != nil, "Set WICKET_CAPTURE_DIR to draw the panels offscreen"),
  arguments: states.filter { captureStates?.contains($0) ?? true })
func panelCapture(_ state: String) async throws {
  let directory = URL(fileURLWithPath: try #require(captureDirectory))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for dark in [false, true] {
    let scenario = try await Scenario.make(state, dark: dark, folder: "\(state)-\(dark)")
    // Under the load of this run, with every state drawn at once, WebKit took up to five seconds to load
    // its empty page, more than the fixed wait there was: wait for the render.
    await scenario.controller?.renderer.settled()
    let target = directory.appending(path: "\(state)-\(dark ? "dark" : "light").png")
    try await Task.sleep(for: .seconds(1))
    // What the panel draws is what the screens committed last: no change to them went undrawn.
    if let controller = scenario.controller {
      #expect(
        controller.presentation == scenario.model.navigator.presentation, "\(state) drew a stale screen")
    }
    try await render(scenario.view, to: target)
    if state == "weather-page" || state == "weather-default" {
      let renderer = try #require(scenario.controller?.renderer)
      let page = try #require(renderer.page)
      // Measure before the renderer's cap, which would hide overflowing content.
      let height = try await page.callJavaScript(
        "return document.querySelector('main').getBoundingClientRect().height;",
        arguments: [:], contentWorld: .defaultClient)
      let measured = try #require(height as? Double)
      #expect(
        measured > 0 && measured.rounded(.up) <= renderer.cap,
        "Weather content is \(measured) points high; the panel allows \(renderer.cap).")
    }
    let text = try recognizedText(in: target)
    let missing = expectedText(state).filter { !text.localizedCaseInsensitiveContains($0) }
    #expect(missing.isEmpty, "\(target.lastPathComponent) is missing \(missing). Recognized text: \(text)")
    #expect(!text.isEmpty, "\(target.lastPathComponent) is blank")
    if state == "settings-window" || state == "settings-extensions" {
      #expect(!text.localizedCaseInsensitiveContains("Show in Finder"))
    }
    await scenario.finish()
  }
}

/// Always runs. Sets every state up the way the capture does, without drawing, so the capture
/// code does not rot between the owner's occasional runs.
@MainActor @Test(arguments: states)
func scenariosSetUpTheirState(_ state: String) async throws {
  let scenario = try await Scenario.make(state, dark: false)
  let model = scenario.model
  switch state {
  case "arrival-root-held":
    #expect(
      model.navigator.command == nil && model.navigator.sizedRows == 8
        && model.navigator.returnPlan() != .wait)
  case "arrival-running", "asking-running-back", "arrival-typed", "arrival-dictated":
    #expect(
      model.navigator.command?.id == "extension:slow" && model.navigator.command?.busy == true
        && !model.agent.active)
    #expect(
      model.navigator.input
        == ["arrival-typed": "fin", "arrival-dictated": "Finished yet?"][state, default: ""])
  case "arrival-page-ready":
    #expect(model.navigator.body?.contains("Weekly report") == true && model.navigator.results.count == 1)
  case "arrival-back-held", "conversation-back-command":
    #expect(
      model.navigator.command?.id == "extension:notes"
        && model.navigator.results.map(\.row.title) == ["Groceries", "Ideas"])
    #expect(!model.agent.active)
  case "extension-actions":
    #expect(
      model.navigator.actionsTitle == "Weekly report"
        && model.navigator.results.map(\.row.title) == ["Copy", "Refresh"])
  case "answer-actions": #expect(model.navigator.actionsTitle == "Swift Testing" && model.agent.active)
  case "extension-nested-detail":
    #expect(model.navigator.inDetail && model.navigator.page?.source.hasPrefix("## Known issues") == true)
  case "extension-actions-back", "answer-actions-back":
    #expect(model.navigator.actionsTitle == nil && model.navigator.selectedTarget == "#0")
  case "asking-running-command":
    #expect(
      model.agent.active && model.navigator.returnsOnEscape && model.navigator.askingAbout == "Slow list")
  case "history-back":
    #expect(
      model.navigator.command?.id == "history" && !model.agent.active && model.navigator.results.count == 2)
  case "hotkey-command-error":
    #expect(
      model.navigator.command?.id == "extension:mover"
        && model.navigator.command?.problem?.contains("REPAIR") == true)
  case "hotkey-binding":
    #expect(model.navigator.results.compactMap { model.navigator.hotkey(of: $0) }.count == 2)
  case "settings-quicklinks-add", "settings-quicklinks-edit", "settings-quicklinks-search",
    "settings-window-add", "settings-window-invalid":
    #expect(scenario.controller == nil && scenario.view.frame.width == 420)
  case _ where state.hasPrefix("settings-"):
    #expect(scenario.controller == nil && scenario.view.frame.size == SettingsPane.size)
  case _ where state.hasPrefix("permission"): #expect(model.agent.permissions.count == 1)
  case "working": #expect(model.agent.busy && model.agent.answer.isEmpty)
  case "working-text": #expect(model.agent.busy && !model.agent.answer.isEmpty)
  case "conversation-reopen":
    #expect(model.agent.continuing && model.navigator.input == "Could this work offline?")
  case _ where state.hasPrefix("conversation"):
    #expect(
      model.agent.active && !model.agent.busy && model.agent.previous.count == 1
        && model.agent.answer.contains("Build something useful"))
  case _ where state.hasPrefix("answer"):
    #expect(
      model.agent.active && model.agent.answer.contains("A good start")
        && model.agent.status == "Ready for a follow-up")
  case "extension-detail", "extension-detail-larger":
    #expect(model.navigator.command != nil && model.navigator.body?.contains("A useful extension") == true)
    #expect(model.navigator.results.isEmpty && model.navigator.askingAbout == "Extension report")
  case "asking", "asking-extension":
    #expect(model.agent.active && model.agent.question.isEmpty && model.navigator.returnsOnEscape)
    #expect(model.navigator.askingAbout == (state == "asking" ? nil : "Extension report"))
  case "extension-both":
    #expect(
      model.navigator.body?.contains("A useful extension") == true && model.navigator.results.count == 2)
    #expect(model.navigator.selected?.row.id == "detail")
  case "actions": #expect(model.navigator.actionsTitle == "Settings" && model.navigator.results.count == 2)
  case "extension-targets":
    #expect(
      model.navigator.results.count == 9 && model.navigator.selected?.row.title == "10° 7°"
        && model.navigator.selectedTarget == "#2")
  case "fields-empty":
    #expect(model.navigator.fieldSlots.count == 2 && model.navigator.fieldValues.isEmpty)
  case "fields-filled":
    #expect(
      model.navigator.command == nil && model.navigator.fieldValues == ["hours": "12", "minutes": "30"])
  case "fields-command":
    #expect(
      model.navigator.fieldValues.count == 2
        && model.navigator.results.first?.row.title == "Awake for 12 h 30 min")
  case "fields-open", "fields-long":
    #expect(model.navigator.command != nil && model.navigator.fieldValues.isEmpty)
  case "fields-three": #expect(model.navigator.fieldSlots.count == 3)
  case "extension-error": #expect(model.navigator.command?.problem?.contains("REPAIR") == true)
  case "history": #expect(model.navigator.command?.id == "history" && model.navigator.results.count == 2)
  case "clipboard":
    #expect(model.navigator.splits && model.navigator.selected?.row.title.hasPrefix("func greet") == true)
    #expect(model.navigator.preview?.page.source.contains("Hello") == true)
  case "clipboard-image":
    #expect(model.navigator.splits && model.navigator.selected?.row.title == "Image 1200×800")
    #expect(model.navigator.preview?.page.picture != nil)
  case "history-reopened":
    #expect(model.agent.continuing && model.agent.previous.count == 1 && model.agent.sessionID == "s")
  case "extension-pattern":
    let decimal = ProviderRequest.NumberMarks.current.decimal
    #expect(model.navigator.results.first?.row.title.contains("6\(decimal)21") == true)
  case "extension-quicklinks-empty":
    #expect(model.navigator.results.map(\.row.title) == ["Add a Quicklink…"])
  case "extension-list": #expect(model.navigator.command != nil && !model.navigator.results.isEmpty)
  case "weather-keyword":
    #expect(model.navigator.command == nil && model.navigator.fieldSlots.isEmpty)
    #expect(model.navigator.input == "weather " && model.navigator.hasFieldNavigation)
  case "weather-root":
    #expect(
      model.navigator.command == nil && model.navigator.prominentFirst && model.navigator.fieldSlots.isEmpty)
    #expect(model.navigator.hasFieldNavigation)
    #expect(model.navigator.results.filter { $0.provider == "extension:weather" }.count == 1)
  case "weather-page", "weather-default":
    #expect(model.navigator.command?.id == "extension:weather")
    #expect(model.navigator.body?.contains("### Next days") == true)
    if state == "weather-default" { #expect(model.navigator.input.isEmpty) }
  case "listening":
    #expect(scenario.controller?.input.speaking == true && model.navigator.input == "How do rainbows form?")
  case "empty": #expect(model.navigator.results.map(\.row.title) == ["Calculator", "Calendar", "Chess"])
  default: #expect(!model.navigator.results.isEmpty)
  }
  #expect(scenario.controller?.panel.isVisible != true && scenario.controller?.panel.isKeyWindow != true)
  await scenario.finish()
}

// Opt-in answer gallery for design work: draws each question and reply of a JSON file, an array of
// `[question, reply]` followed by an optional text size (`small`, `large`, `larger`) and keys pressed
// once it has arrived (`down`, `up`, `return`, so a target can be selected or its detail opened, `escape`
// and `actions` for ⌘K), as an
// answer in light and dark, named `01-light.png`, `01-dark.png` and so on:
//
//   WICKET_REPLIES=replies.json WICKET_CAPTURE_DIR=/tmp/look swift test --filter replyCapture
//
// `Fixtures/capture-replies.json` is the set compared across refactors: a long reply at each text size,
// targets, a nested detail and the action panel, each with Escape back.

private let replies: [[String]] =
  ProcessInfo.processInfo.environment["WICKET_REPLIES"].flatMap {
    try? JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
  } ?? []

@MainActor
@Test(
  .enabled(if: captureDirectory != nil && !replies.isEmpty, "Set WICKET_REPLIES and WICKET_CAPTURE_DIR"),
  arguments: replies.indices)
func replyCapture(_ index: Int) async throws {
  let directory = URL(fileURLWithPath: try #require(captureDirectory))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let entry = replies[index]
  let size = entry.dropFirst(2).first { ["small", "large", "larger"].contains($0) }
  for dark in [false, true] {
    try await renderReply(
      (entry[0], entry[1]), dark: dark, size: size, keys: entry.dropFirst(2),
      to: directory.appending(path: String(format: "%02d-%@.png", index + 1, dark ? "dark" : "light")))
  }
}

@MainActor
func renderReply(
  _ turn: (question: String, reply: String), dark: Bool, size: String? = nil,
  keys: ArraySlice<String> = [], to url: URL
) async throws {
  let scenario = try await Scenario.make(
    "answer" + (size.map { "-" + $0 } ?? ""), dark: dark, turn: turn)
  do {
    // Only keys the model handles itself: Return dispatches a detail or a follow-up, never an effect.
    for key in keys {
      switch key {
      case "down": scenario.model.navigator.move(1)
      case "up": scenario.model.navigator.move(-1)
      case "return": scenario.model.activateReturn()
      case "escape": _ = scenario.model.navigator.escape()
      case "actions": scenario.model.navigator.toggleActions()
      default: break
      }
    }
    await scenario.controller?.renderer.settled()
    try await Task.sleep(for: .seconds(1))
    try await render(scenario.view, to: url)
    await scenario.finish()
  } catch {
    await scenario.finish()
    throw error
  }
}
