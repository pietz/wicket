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
// Every state is drawn offscreen in light and dark: no window is ordered front or made key, no
// event is posted, no real agent, microphone or global shortcut is used, and nothing outside
// scratch folders and the capture folder is touched. Surfaces are solid, because glass does not
// render offscreen. The captures prove layout and foreground, not glass, focus or shadows. Each
// capture is read back with text recognition and must show the content its state promises.
// Without the variable the capture test is skipped and `scenariosSetUpTheirState` still checks
// the setup of every state without drawing anything.

private let captureDirectory = ProcessInfo.processInfo.environment["WICKET_CAPTURE_DIR"]

private let states = [
  "empty", "apps", "math", "ask", "answer", "listening",
  "conversation-multi", "conversation-expanded", "conversation-reopen", "conversation-long",
  "conversation-long-expanded",
  "working", "permission-routine", "permission-high",
  "answer-small", "answer-large", "answer-larger", "apps-larger", "permission-routine-larger",
  "extension-pattern", "extension-fallback", "extension-list", "extension-detail", "extension-both",
  "extension-error", "arguments-empty", "arguments-filled", "arguments-command", "arguments-open",
  "arguments-long", "arguments-three",
  "settings-general", "settings-voice", "settings-agent", "settings-sources", "settings-error",
  "settings-conflict",
]

/// What text recognition must find, so a blank or broken panel fails.
private func expectedText(_ name: String) -> [String] {
  if name.contains("settings-general") { return ["Text size", "Medium", "Open Wicket", "Launch at login"] }
  if name.contains("settings-sources") { return ["Sources", "Weather"] }
  if name.contains("settings-") { return [] }
  if name.contains("permission-high") {
    return ["Allow Claude to delete files", "Deletes", "Show details", "Allow deletion"]
  }
  if name.contains("permission-routine") {
    return [
      "Allow Claude to edit files", "Update the weather extension", "2 files", "Don't allow", "Allow once",
    ]
  }
  if name.contains("conversation-reopen") {
    return ["Could this work offline", "Continuing conversation", "End conversation"]
  }
  if name.contains("conversation-expanded") {
    return [
      "Ask a follow-up", "Previous questions", "How is the launch going", "A good start",
      "What should I build next", "End conversation",
    ]
  }
  if name.contains("conversation-long") {
    return ["Ask a follow-up", "How can I improve", "Show", "Build something useful"]
  }
  if name.contains("conversation") {
    return ["Ask a follow-up", "Previous questions", "What should I build next", "Build something useful"]
  }
  if name.contains("working") { return ["What should I build next", "Thinking", "Cancel"] }
  if name.contains("listening") { return ["rainbows", "Ask agent", "Listening", "Ask", "Close"] }
  if name.contains("extension-detail") {
    return ["Extension report", "A useful extension", "42", "Local extension", "One JSON view", "Actions"]
  }
  if name.contains("extension-both") {
    return [
      "Extension report", "A useful extension", "Local extension", "Hourly forecast", "Weekly forecast",
      "Actions",
    ]
  }
  if name.contains("extension-error") {
    return ["Extension report", "Invalid extension view", "REPAIR", "Ask agent"]
  }
  if name.contains("arguments-empty") { return ["caff", "Caffeinate", "hours", "minutes"] }
  if name.contains("arguments-filled") { return ["caff", "Caffeinate", "12", "30"] }
  if name.contains("arguments-open") { return ["Caffeinate", "hours", "minutes"] }
  if name.contains("arguments-long") { return ["hours", "minutes", "Awake"] }
  if name.contains("arguments-three") { return ["caff", "hours", "minutes", "seconds"] }
  if name.contains("arguments-command") { return ["Caffeinate", "12", "30", "Awake for 12 h 30 min"] }
  if name.contains("extension-pattern") { return ["6.2137119", "Copy conversion", "Ask agent"] }
  if name.contains("extension-list") { return ["wicket launcher", "Search for", "Search the web"] }
  if name.contains("extension-fallback") { return ["Ask agent", "Search the web"] }
  if name.contains("answer") {
    return ["Ask a follow-up", "A good start", "Extensions", "Ready for a follow-up"]
  }
  if name.contains("math") { return ["200", "28", "Ask agent"] }
  if name.contains("ask") { return ["rainbows", "Ask agent"] }
  if name.contains("empty") { return ["Search", "Calculator", "Ask agent", "Open", "Close"] }
  return ["cal", "Calculator", "Calendar", "Ask agent", "Open", "Close"]
}

private let launchAnswer =
  "<answer value=\"A good start\" detail=\"Twelve extensions, all local\"/>\n<stat label=\"Extensions\" value=\"12\" delta=\"+3 this week\" tone=\"positive\"/>\n<stat label=\"Response\" value=\"42 ms\"/>\n<callout tone=\"warning\">Restart once after updating.</callout>\n<fact label=\"Owner\" value=\"You\"/>\n<fact label=\"Next\" value=\"Build something useful\"/>\n<bar label=\"Disk used\" value=\"420 of 600 GB\" percent=\"70\"/>\n<event time=\"14:30\" title=\"Train departs\" detail=\"Platform 6\"/>\n<event time=\"16:05\" title=\"Arrives in Berlin\"/>\n<badge label=\"Healthy\" tone=\"positive\"/> <badge label=\"v2.4\"/>\n<item title=\"Swift Testing\" subtitle=\"Apple guide\" open=\"https://developer.apple.com/documentation/testing\"/>\n<item title=\"Copy the summary\" copy=\"A good start\"/>\n<item title=\"How do I add an extension?\" ask=\"How do I add an extension?\"/>"
private let nextAnswer =
  "## Build something useful\nStart with a small weather extension. Put the current temperature in its result row, with the full forecast one step away.\n\nKeep it **local**, quick and easy to change."

/// A panel that can never become key, so nothing here can take focus even by accident.
@MainActor private final class CapturePanel: PalettePanel {
  override var canBecomeKey: Bool { false }
}

@MainActor private final class FixedApps: Provider {
  let id = "apps"
  private let index = SearchIndex(
    ["Calendar", "Calculator", "Chess"].map { name in
      Row(
        id: name.lowercased(), title: name, subtitle: "Application",
        actions: [.open(URL(fileURLWithPath: "/System/Applications/" + name + ".app"))])
    })
  func view(for request: ProviderRequest) async throws -> ProviderView {
    .init(items: index.matches(request.input))
  }
}

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
    await model.finish()
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

  static func make(_ state: String, dark: Bool) async throws -> Scenario {
    _ = NSApplication.shared
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let folder = try scratch()
    try AnswerRenderer.installFiles(in: folder)
    if state.hasPrefix("settings-") {
      return try await settings(state, folder: folder, appearance: appearance)
    }

    let (name, size) = textSize(state)
    let transcriber = FakeTranscriber()
    let model = LauncherModel(
      providers: [MathProvider(), FixedApps()],
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
      transcriber: { transcriber })
    model.store.update {
      $0.voice.enabled = name == "listening"
      $0.textSize = size
      $0.agent.streamAnswers = false
    }
    let panel = CapturePanel()
    panel.appearance = appearance
    let controller = PaletteController(model: model, flatSurfaces: true, panel: panel)
    let scenario = Scenario(
      model: model, controller: controller, view: panel.contentView!, window: nil, folder: folder)
    scenario.keep.append(transcriber)

    if name.hasPrefix("answer") || name.hasPrefix("conversation") {
      try await finishTurn(model.agent, "How is the launch going?", launchAnswer)
    }
    switch name {
    case "apps": model.input = "cal"
    case "math": model.input = "200*10%+2^3"
    case "ask": model.input = "How do rainbows form?"
    case "listening":
      model.armVoice()
      transcriber.feeds[0].yield(.ready)
      transcriber.feeds[0].yield(.transcript("How do rainbows form?"))
      #expect(await eventually { model.input == "How do rainbows form?" })
    case "conversation-reopen":
      model.input = "Could this work offline?"
      model.dismiss()
      model.reopen()
    case _ where name.hasPrefix("conversation") || name.hasPrefix("permission") || name == "working":
      let agent = FakeAgent()
      scenario.keep.append(agent)
      model.agent.connect = { _, _, _ in agent }
      let question =
        name.hasPrefix("conversation-long")
        ? String(
          repeating: "How can I improve this launcher while keeping the experience calm and native? ",
          count: 5)
        : (name.hasPrefix("permission") ? "Update the weather extension" : "What should I build next?")
      model.send(question)
      #expect(await eventually { agent.running })
      if name.hasPrefix("permission") {
        agent.onEvent(.permission(permissionRequest(high: name == "permission-high", folder: folder)))
        #expect(await eventually { !model.agent.permissions.isEmpty })
      } else if name != "working" {
        agent.text(nextAnswer)
        agent.end()
        #expect(await eventually { !model.agent.busy })
      }
      if name == "conversation-expanded" { model.historyExpanded = true }
      if name == "conversation-long-expanded" { model.questionExpanded = true }
    case _ where name.hasPrefix("extension-"): try await configureExtension(name, model)
    case _ where name.hasPrefix("arguments-"): try await configureArguments(name, model)
    default: break
    }
    controller.show(orderFront: false, listen: false)
    await model.settled()
    return scenario
  }

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
    if ["extension-detail", "extension-both", "extension-error"].contains(state) {
      let demo = folder.appending(path: "extensions/demo")
      try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: [
        "name": "Extension report", "keyword": "demo", "command": ["/usr/bin/python3", "main.py"],
        "icon": "doc.text",
      ]).write(to: demo.appending(path: "wicket.json"))
      let both = state == "extension-both"
      let view = ProviderView(
        body:
          "## A useful extension\n<stat label=\"Total\" value=\"42\"/>\n<callout>Written by a program, displayed by Wicket.</callout>\n<fact label=\"Source\" value=\"Local extension\"/>\n<fact label=\"Format\" value=\"One JSON view\"/>",
        items: both
          ? [
            Row(
              id: "hourly", title: "Hourly forecast", subtitle: "Next 24 hours", icon: "clock",
              actions: [.run(Address(arguments: ["view": "hourly"]), title: "Hourly")]),
            Row(
              id: "weekly", title: "Weekly forecast", subtitle: "Next 7 days", icon: "calendar",
              actions: [.run(Address(arguments: ["view": "weekly"]), title: "Weekly")]),
          ] : [],
        actions: [
          .copy("42"), .run(Address(arguments: ["refresh": "true"]), title: "Refresh"),
          .agent("Explain this report"),
        ])
      try JSONEncoder().encode(view).write(to: demo.appending(path: "view.json"))
      let code =
        state == "extension-error"
        ? "import json,sys; json.load(sys.stdin); sys.stderr.write('REPAIR: missing closing brace in main.py\\n'); print('{broken')"
        : "import json,sys; json.load(sys.stdin); sys.stdout.write(open('view.json').read())"
      try Data(code.utf8).write(to: demo.appending(path: "main.py"))
      await host.reload()
      model.input = "demo"
      await model.settled()
      _ = model.activateReturn()
      await model.settled()
    } else {
      let web = folder.appending(path: "extensions/web-search")
      if !FileManager.default.fileExists(atPath: web.path) {
        try FileManager.default.copyItem(at: folder.appending(path: "examples/web-search"), to: web)
      }
      await host.reload()
      switch state {
      case "extension-list":
        model.input = "web"
        await model.settled()
        _ = model.activateReturn()
        await model.settled()
        model.input = "wicket launcher"
      case "extension-fallback": model.input = "a useful sentence to search"
      default: model.input = "10 km in mi"
      }
      await model.settled()
    }
  }

  /// A command with two declared arguments (three in `arguments-three`), as the root row with its slots
  /// and as the open command: filled, empty, and with a long input pushing the slots to the end.
  private static func configureArguments(_ state: String, _ model: LauncherModel) async throws {
    let folder = model.agent.folder.appending(path: "extensions/caffeinate")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "name": "Caffeinate", "command": ["/usr/bin/python3", "main.py"], "icon": "cup.and.saucer",
      "arguments": [["name": "hours", "placeholder": "hours"], ["name": "minutes"]]
        + (state == "arguments-three" ? [["name": "seconds"]] : []),
    ]).write(to: folder.appending(path: "wicket.json"))
    let code = """
      import json,sys; a=json.load(sys.stdin)['arguments']
      print(json.dumps({'items':[{'id':'awake','title':'Awake for %s h %s min' % (a.get('hours','0'), a.get('minutes','0')),'actions':[]}]}))
      """
    try Data(code.utf8).write(to: folder.appending(path: "main.py"))
    await model.extensions.reload()
    model.input = "caff"
    await model.settled()
    if state == "arguments-filled" || state == "arguments-command" {
      model.setArgument("hours", to: "12")
      model.setArgument("minutes", to: "30")
    }
    if ["arguments-command", "arguments-open", "arguments-long"].contains(state) {
      _ = model.activateReturn()
      await model.settled()
    }
    if state == "arguments-long" {
      model.input = "a long note about why the build server should stay awake through the night"
      await model.settled()
    }
  }

  private static func settings(_ state: String, folder: URL, appearance: NSAppearance?) async throws
    -> Scenario
  {
    try ExtensionHost.installFiles(in: folder)
    let store = ConfigurationStore(url: folder.appending(path: "config.json"))
    var initial = Configuration()
    initial.agent.model = "sonnet"
    if state == "settings-sources" {
      let weather = folder.appending(path: "extensions/weather")
      try FileManager.default.createDirectory(at: weather, withIntermediateDirectories: true)
      try Data(#"{"name":"Weather","command":["/usr/bin/python3","main.py"]}"#.utf8).write(
        to: weather.appending(path: "wicket.json"))
      try Data("print('weather')".utf8).write(to: weather.appending(path: "main.py"))
      initial.providers.append(.init("extension:weather", enabled: false))
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
    let host = ExtensionHost(folder: folder)
    await host.reload()
    store.start(watching: false)
    if state == "settings-error" {
      try Data("{".utf8).write(to: store.url, options: .atomic)
      store.load()
    }
    if state == "settings-conflict" { store.hotkeyProblem = "⌃K is in use. ⌥Space still opens Wicket." }
    let section =
      ["settings-general", "settings-voice", "settings-agent", "settings-sources"].firstIndex(of: state) ?? 0
    let pane = NSHostingView(
      rootView: SettingsPane(
        section: section, store: store, extensions: host,
        clipboard: ClipboardHistory(
          url: folder.appending(path: "clipboard-history.json"),
          pasteboard: NSPasteboard(name: .init(UUID().uuidString)),
          interval: nil),
        updater: nil, pauseHotkey: { _ in }))
    pane.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
    let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = pane
    let model = LauncherModel(
      providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder)
    let scenario = Scenario(model: model, controller: nil, view: pane, window: window, folder: folder)
    scenario.keep.append(store)
    scenario.keep.append(host)
    return scenario
  }
}

/// Draws the view offscreen. Web views are drawn from their own snapshots: the composited layer of a
/// web view in a window that is never shown sometimes stays blank however long one waits (whole
/// batches of pages did, now and then), while a snapshot is rendered by WebKit itself.
@MainActor private func render(_ view: NSView, to url: URL) async throws {
  view.layoutSubtreeIfNeeded()
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    throw ExtensionFailure("No render target")
  }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  func webViews(_ view: NSView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
  }
  for web in webViews(view) where !web.isHiddenOrHasHiddenAncestor && !web.visibleRect.isEmpty {
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
  try bitmap.representation(using: .png, properties: [:])?.write(to: url)
}

private func recognizedText(in url: URL) throws -> String {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  try VNImageRequestHandler(url: url).perform([request])
  return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

@MainActor
@Test(
  .enabled(if: captureDirectory != nil, "Set WICKET_CAPTURE_DIR to draw the panels offscreen"),
  arguments: states)
func panelCapture(_ state: String) async throws {
  let directory = URL(fileURLWithPath: try #require(captureDirectory))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for dark in [false, true] {
    let scenario = try await Scenario.make(state, dark: dark)
    // Under the load of this run, with every state drawn at once, WebKit took up to five seconds to load
    // its empty page, more than the fixed wait there was: wait for the render.
    await scenario.controller?.renderer.settled()
    let target = directory.appending(path: "\(state)-\(dark ? "dark" : "light").png")
    try await Task.sleep(for: .seconds(1))
    try await render(scenario.view, to: target)
    let text = try recognizedText(in: target)
    let missing = expectedText(state).filter { !text.localizedCaseInsensitiveContains($0) }
    #expect(missing.isEmpty, "\(target.lastPathComponent) is missing \(missing). Recognized text: \(text)")
    #expect(!text.isEmpty, "\(target.lastPathComponent) is blank")
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
  case _ where state.hasPrefix("settings-"):
    #expect(scenario.controller == nil && scenario.view.frame.size == CGSize(width: 560, height: 480))
  case _ where state.hasPrefix("permission"): #expect(model.agent.permissions.count == 1)
  case "working": #expect(model.agent.busy && model.agent.answer.isEmpty)
  case "conversation-reopen": #expect(model.agent.continuing && model.input == "Could this work offline?")
  case _ where state.hasPrefix("conversation"):
    #expect(
      model.agent.active && !model.agent.busy && model.agent.previous.count == 1
        && model.agent.answer.contains("Build something useful"))
  case _ where state.hasPrefix("answer"):
    #expect(
      model.agent.active && model.agent.answer.contains("A good start")
        && model.agent.status == "Ready for a follow-up")
  case "extension-detail":
    #expect(model.command != nil && model.body?.contains("A useful extension") == true)
    #expect(model.results.isEmpty)
  case "extension-both":
    #expect(model.body?.contains("A useful extension") == true && model.results.count == 2)
    #expect(model.selected?.row.id == "detail")
  case "arguments-empty": #expect(model.declaredArguments.count == 2 && model.argumentValues.isEmpty)
  case "arguments-filled":
    #expect(model.command == nil && model.argumentValues == ["hours": "12", "minutes": "30"])
  case "arguments-command":
    #expect(model.argumentValues.count == 2 && model.results.first?.row.title == "Awake for 12 h 30 min")
  case "arguments-open", "arguments-long": #expect(model.command != nil && model.argumentValues.isEmpty)
  case "arguments-three": #expect(model.declaredArguments.count == 3)
  case "extension-error": #expect(model.command?.problem?.contains("REPAIR") == true)
  case "extension-pattern": #expect(model.results.first?.row.title.contains("6.21") == true)
  case "extension-fallback": #expect(model.results.contains { $0.row.id == "fallback" })
  case "extension-list": #expect(model.command != nil && !model.results.isEmpty)
  case "listening": #expect(model.voice?.active == true && model.input == "How do rainbows form?")
  case "empty": #expect(model.results.map(\.row.title) == ["Calculator", "Calendar", "Chess", "Ask agent"])
  default: #expect(!model.results.isEmpty)
  }
  #expect(scenario.controller?.panel.isVisible != true && scenario.controller?.panel.isKeyWindow != true)
  await scenario.finish()
}
