import AppKit
import Testing

@testable import WicketApp

private func withSettings(_ json: String = "{}", _ test: (ConfigurationFile) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = ConfigurationFile(url: root.appending(path: "config.json"))
  try Data(json.utf8).write(to: file.url)
  try test(file)
}

@Test func settingsPreserveUnknownKeysAndTheWrittenProviderList() throws {
  try withSettings(
    #"{"future":{"list":[1,true,"x"]},"voice":{"future":42},"agent":{"future":"keep"},"providers":[{"id":"apps","enabled":true,"future":7},{"id":"extension:test","enabled":false},{"id":"math","enabled":true}]}"#
  ) { file in
    try file.set("enabled", to: false, in: "voice")
    // An earlier version's microphone choice is kept in the file and ignored.
    try file.set("microphone", to: "stable-uid", in: "voice")
    #expect(try Configuration.load(at: file.url).voice == Configuration.Voice(enabled: false))
    try file.set("model", to: "sonnet", in: "agent")
    try file.setProvider("apps", enabled: false)
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["future"] == .object("list", .array([.number(1), .bool(true), .string("x")])))
    #expect(json["voice"]["future"] == .number(42))
    #expect(json["voice"]["microphone"] == .string("stable-uid"))
    #expect(json["agent"]["future"] == .string("keep"))
    #expect(json["providers"].array[0]["future"] == .number(7))
    #expect(try Configuration.load(at: file.url).providers.map(\.id) == ["apps", "extension:test", "math"])
  }
}

@Test func settingsWriteEachValueAndSwitchAgentWithoutCarryingOptions() throws {
  try withSettings { file in
    #expect(try !Configuration.load(at: file.url).resultsOnlyWhenTyping)
    try file.set("resultsOnlyWhenTyping", to: true)
    try file.set("hotkey", to: "ctrl+option+k")
    try file.set("backgroundTransparency", to: 0.65)
    try file.set("enabled", to: false, in: "voice")
    try file.selectAgent("codex")
    for (key, value) in [("model", "gpt-6"), ("effort", "high"), ("mode", "workspace-write")] {
      try file.set(key, to: value, in: "agent")
    }
    try file.setProvider("files", enabled: false)
    try file.setProvider("extension:new", enabled: true)
    let config = try Configuration.load(at: file.url)
    #expect(config.resultsOnlyWhenTyping)
    #expect(config.hotkey == (try Shortcut("ctrl+option+k")))
    #expect(config.backgroundTransparency == 0.65 && !config.voice.enabled)
    #expect(config.agent.agent == .codex && config.agent.model == "gpt-6")
    #expect(config.agent.effort == "high" && config.agent.mode == "workspace-write")
    #expect(
      config.providers == [
        .init("apps"), .init("files", enabled: false), .init("clipboard", enabled: false),
        .init("extension:new"),
      ])
    try file.set("model", to: nil, in: "agent")
    #expect(try Configuration.load(at: file.url).agent.model == nil)
    try file.selectAgent("claude")
    #expect(try Configuration.load(at: file.url).agent == AgentConfiguration())
  }
}

@Test(arguments: [
  (#"{"resultsOnlyWhenTyping":true}"#, true),
  (#"{"compactOnOpen":true}"#, true),
  (#"{"compactOnOpen":true,"resultsOnlyWhenTyping":false}"#, false),
  (#"{"compactOnOpen":false,"resultsOnlyWhenTyping":true}"#, true),
  (#"{"compactOnOpen":true,"resultsOnlyWhenTyping":null}"#, false),
])
func resultsOnlyWhenTypingReadsTheLegacyKeyOnlyWhenTheNewKeyIsAbsent(json: String, expected: Bool) throws {
  try withSettings(json) { file in
    let configuration = try Configuration.load(at: file.url)
    #expect(configuration.resultsOnlyWhenTyping == expected)
  }
}

@Test func savingSettingsCarriesTheLegacyResultsPreferenceForward() throws {
  try withSettings(#"{"compactOnOpen":true,"future":42}"#) { file in
    try file.set("appearance", to: "dark")
    let written = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
    #expect(written["resultsOnlyWhenTyping"] as? Bool == true)
    #expect(written["compactOnOpen"] == nil)
    #expect(written["future"] as? Int == 42)
  }
}

@MainActor @Test func resultsOnlyWhenTypingToggleWritesOnlyTheNewKey() throws {
  try withSettings(#"{"compactOnOpen":true}"#) { file in
    let root = file.url.deletingLastPathComponent()
    let store = ConfigurationStore(url: file.url)
    store.start(watching: false)
    let pane = SettingsPane(
      section: 0, store: store, extensions: ExtensionHost(folder: root, bundled: nil),
      clipboard: ClipboardHistory(
        url: root.appending(path: "clipboard.json"), pasteboard: FakePasteboard(), interval: nil),
      runs: AgentHistory(url: root.appending(path: "runs.json")), updater: nil, pauseHotkey: { _ in })
    #expect(pane.resultsOnlyWhenTyping.wrappedValue)
    pane.resultsOnlyWhenTyping.wrappedValue = false
    #expect(!pane.resultsOnlyWhenTyping.wrappedValue)
    let written = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
    #expect(written["resultsOnlyWhenTyping"] as? Bool == false)
    #expect(written["compactOnOpen"] == nil)
  }
}

@Test func settingsReadFreshDiskAndRejectInvalidInputWithoutWriting() throws {
  try withSettings { file in
    try Data(#"{"external":true,"backgroundTransparency":0.8}"#.utf8).write(to: file.url, options: .atomic)
    try file.set("enabled", to: false, in: "voice")
    let good = try Data(contentsOf: file.url)
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.8)
    #expect(try JSONDecoder().decode(JSONValue.self, from: good)["external"] == .bool(true))
    for (key, value) in [
      ("hotkey", "space" as Any), ("backgroundTransparency", 2 as Any), ("providers", false as Any),
    ] {
      #expect(throws: (any Error).self) { try file.set(key, to: value) }
      #expect(try Data(contentsOf: file.url) == good)
    }
    try Data("{".utf8).write(to: file.url)
    #expect(throws: (any Error).self) { try file.set("hotkey", to: "option+k") }
    #expect(try Data(contentsOf: file.url) == Data("{".utf8))
  }
}

@MainActor @Test func settingsLiveReloadAndSharedErrorAndReportedOptions() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigurationStore(url: root.appending(path: "config.json"))
  var launcherProblem: String?
  store.onChange = { [weak store] _ in launcherProblem = store?.problem }
  store.start()
  #expect(await eventually { FileManager.default.fileExists(atPath: store.url.path) })
  try AgentDiscovery.save([AgentModel(id: "reported-only")], agent: .claude, in: root)
  #expect(await eventually { store.models.map(\.id) == ["reported-only"] })
  try Data(#"{"voice":{"enabled":false},"hotkey":"ctrl+k"}"#.utf8).write(to: store.url, options: .atomic)
  #expect(
    await eventually {
      !store.configuration.voice.enabled && store.configuration.hotkey.description == "ctrl+k"
    })
  try Data("{".utf8).write(to: store.url, options: .atomic)
  #expect(await eventually { store.problem != nil })
  #expect(store.problem == launcherProblem && !store.configuration.voice.enabled)
  store.change { try $0.set("enabled", to: true, in: "voice") }
  #expect(store.problem == launcherProblem)
  try Data(#"{"agent":{"name":"codex"}}"#.utf8).write(to: store.url, options: .atomic)
  #expect(
    await eventually {
      store.problem == nil && store.configuration.agent.agent == .codex && store.models.isEmpty
    })
}

@MainActor @Test func changeIsVisibleToTheModelImmediatelyAndInvalidEditsKeepTheLastGoodValue() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  #expect(model.store.change { try $0.set("textSize", to: "large") })
  #expect(model.store.configuration.textSize == .large && model.configuration.textSize == .large)
  try Data("{".utf8).write(to: model.store.url, options: .atomic)
  model.store.load()
  #expect(model.configuration.textSize == .large && model.problem?.hasPrefix("Config:") == true)
  model.store.update { $0.textSize = .small }
  #expect(model.configuration.textSize == .small && model.problem == nil)
}

@MainActor @Test func footerProblemPicksOneSourceInPriorityOrder() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  #expect(model.problem == nil)
  model.navigator.actionProblem = "paste"
  #expect(model.problem == "paste")
  model.installProblem = "install"
  #expect(model.problem == "install")
  model.store.hotkeyProblem = "hotkey"
  #expect(model.problem == "hotkey")
  try Data("{".utf8).write(to: model.store.url, options: .atomic)
  model.store.load()
  #expect(model.problem?.hasPrefix("Config:") == true)
  model.store.update { _ in }
  #expect(model.problem == "hotkey")
  model.navigator.actionProblem = nil
  #expect(model.problem == "hotkey")
  model.store.hotkeyProblem = nil
  #expect(model.problem == "install")
}

@MainActor @Test func settingsHotkeyConflictUsesExistingRegistrationResult() throws {
  let hotkey = HotKeyRegistration { shortcut in shortcut.key == "k" ? nil : Handle() }
  let store = ConfigurationStore(url: URL(fileURLWithPath: "/unused"))
  #expect(hotkey.apply(.default) == nil)
  store.hotkeyProblem = hotkey.apply(try Shortcut("ctrl+k"))
  #expect(store.hotkeyProblem?.contains("⌃K is in use") == true)
  #expect(store.hotkeyProblem?.contains("⌥Space still opens Wicket") == true)
  #expect(hotkey.inEffect == .default)
  hotkey.pause(true)
  #expect(hotkey.apply(.default) == nil)
  #expect(hotkey.inEffect == nil)  // Even an external reload must not register while recording.
  hotkey.pause(false)
  #expect(hotkey.apply(try Shortcut("ctrl+k"))?.contains("⌥Space still opens Wicket") == true)
  #expect(hotkey.inEffect == .default)
}

@Test func settingsWritesReadableDecimalsAndPaths() throws {
  try withSettings(#"{"future":"https://example.com/a"}"#) { file in
    try file.set("backgroundTransparency", to: 0.65)
    try file.set("enabled", to: false, in: "voice")
    let text = try String(contentsOf: file.url, encoding: .utf8)
    #expect(text.contains("0.65") && !text.contains("0.65000000000000002"))
    #expect(text.contains("https://example.com/a"))
  }
}

@MainActor @Test func settingsWriteFailureLeavesValidConfigurationEditable() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigurationStore(url: root.appending(path: "config.json"))
  store.start()
  #expect(await eventually { FileManager.default.fileExists(atPath: store.url.path) })
  store.change { _ in throw CocoaError(.fileWriteNoPermission) }
  #expect(store.problem == nil && store.writeProblem != nil)
  store.change { try $0.set("enabled", to: false, in: "voice") }
  #expect(await eventually { !store.configuration.voice.enabled })
}

@MainActor @Test func transparencyDragCommitsOnceOnReleaseAndRoundsToHundredths() throws {
  try withSettings { file in
    let store = ConfigurationStore(url: file.url)
    let original = try Data(contentsOf: file.url)
    var slider = SliderEdit("backgroundTransparency")
    slider.editingChanged(true, store: store)
    for tick in [0.61, 0.638, 0.654] { slider.value = tick }
    #expect(try Data(contentsOf: file.url) == original && slider.value == 0.654)
    slider.editingChanged(false, store: store)
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.65)
    let written = try Data(contentsOf: file.url)
    slider.editingChanged(false, store: store)
    #expect(slider.value == nil)
    #expect(try Data(contentsOf: file.url) == written)
  }
}

@MainActor @Test func hotkeyRegistersBeforePersistingAndConflictNeverWrites() throws {
  try withSettings { file in
    let store = ConfigurationStore(url: file.url)
    let original = try Data(contentsOf: file.url)
    var attempted: [Shortcut] = []
    let hotkey = HotKeyRegistration { shortcut in
      #expect((try? Data(contentsOf: file.url)) == original)
      attempted.append(shortcut)
      return shortcut.key == "k" ? nil : Handle()
    }
    store.applyHotkey = { hotkey.apply($0) }
    #expect(hotkey.apply(.default) == nil)
    store.setHotkey(try Shortcut("ctrl+k"))
    #expect(store.rejection?.problem != nil && hotkey.inEffect == .default)
    #expect(try Data(contentsOf: file.url) == original)
    for spelling in ["cmd+c", "cmd+v", "cmd+q", "cmd+w", "cmd+shift+z", "cmd+k"] {
      let count = attempted.count
      store.setHotkey(try Shortcut(spelling))
      #expect(store.rejection?.problem.contains("editing or app shortcut") == true)
      #expect(attempted.count == count)
      #expect(try Data(contentsOf: file.url) == original)
    }
    store.setHotkey(try Shortcut("ctrl+j"))
    #expect(store.rejection == nil && store.hotkeyProblem == nil)
    #expect(hotkey.inEffect == (try Shortcut("ctrl+j")))
    #expect(try Configuration.load(at: file.url).hotkey == (try Shortcut("ctrl+j")))
  }
}

@MainActor @Test func closingRecorderWindowRestoresHotkeyWithoutSwallowingMoreKeys() {
  _ = NSApplication.shared
  let window = NSWindow()
  let other = NSWindow()
  let recorder = ShortcutRecorder()
  var pauses: [Bool] = []
  recorder.start(
    in: window, pausing: { pauses.append($0) }, onRecord: { _ in Issue.record("Closing recorded a shortcut") }
  )
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
  #expect(recorder.isRecording && pauses == [true])
  NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
  #expect(!recorder.isRecording && pauses == [true, false])
  recorder.stop()
  #expect(pauses == [true, false])
}

@MainActor @Test func failedHotkeyWriteRestoresRegistrationAndAllowsRetry() throws {
  try withSettings { file in
    let store = ConfigurationStore(url: file.url)
    let hotkey = HotKeyRegistration { _ in Handle() }
    let original = try Data(contentsOf: file.url)
    let folder = file.url.deletingLastPathComponent()
    store.applyHotkey = { hotkey.apply($0) }
    #expect(hotkey.apply(.default) == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    store.setHotkey(try Shortcut("ctrl+j"))
    #expect(store.writeProblem != nil && store.problem == nil && hotkey.inEffect == .default)
    #expect(try Data(contentsOf: file.url) == original)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    store.setHotkey(try Shortcut("ctrl+j"))
    #expect(store.writeProblem == nil)
    #expect(try Configuration.load(at: file.url).hotkey == (try Shortcut("ctrl+j")))
  }
}

@MainActor @Test func settingsResultOpensSettingsWithoutAnExtensionProvider() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root)
  let surface = RecordingSurface()
  model.navigator.surface = surface
  model.navigator.input = "Settings"
  #expect(model.navigator.results.map(\.provider) == ["settings"])
  #expect(model.navigator.selected?.row.title == "Settings" && model.activateReturn())
  #expect(surface.count(.settings) == 1 && !model.agent.active)
  model.navigator.input = "unmatched sentence"
  #expect(model.navigator.results.first?.provider == "agent")
  await model.finish()
}

@MainActor @Test func bundledExtensionsSupersedeExamplesWithoutChangingExistingInstalls() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  // Official extensions ship inside the app, so nothing is installed into extensions.
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "extensions").path).isEmpty)
  #expect(
    FileManager.default.fileExists(atPath: root.appending(path: "examples/canvas-controls/main.py").path))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "examples").path).sorted()
      == ["agenda", "canvas-controls"])
  let names = ["currency", "quicklinks", "web-search"]
  let installed = try names.map { try extensionFolder(root, name: $0, script: "echo keep") }
  try ExtensionHost.installFiles(in: root)
  for folder in installed {
    #expect(try String(contentsOf: folder.appending(path: "main.sh"), encoding: .utf8) == "echo keep")
  }
  let (commands, problems, _) = ExtensionHost.discover(
    root.appending(path: "extensions"), bundled: bundledExtensions)
  #expect(problems.isEmpty)
  for name in names + ["units", "links-search"] {
    #expect(commands["extension:" + name] != nil)
  }
}

// MARK: - Extension settings

@Test func aManifestDeclaresTypedSettingsWithDefaults() throws {
  func manifest(_ json: String) throws -> ExtensionManifest {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
  }
  let window = try manifest(
    #"{"contract":2,"name":"W","description":"Moves windows.","command":["./main"],"settings":[{"name":"gap","type":"number","description":"Window margin","placeholder":"Gap","default":"0"},{"name":"note","type":"text","description":"Note"}]}"#
  )
  #expect(window.description == "Moves windows." && window.settings.map(\.name) == ["gap", "note"])
  guard case .field(let gap) = window.settings[0], case .field(let note) = window.settings[1] else {
    Issue.record("Expected scalar settings")
    return
  }
  #expect(gap.default == "0" && note.placeholder == nil)
  for invalid in [
    #"{"contract":2,"name":"W","command":["x"],"settings":[{"name":"a","type":"text","description":"A"},{"name":"a","type":"text","description":"A"}]}"#,
    #"{"contract":2,"name":"W","command":["x"],"settings":[{"name":"","type":"text","description":"A"}]}"#,
    #"{"name":"W","items":[],"settings":[{"name":"a","type":"text","description":"A"}]}"#,
    #"{"contract":2,"name":"W","command":["x"],"fields":[{"name":"a","type":"text","description":"A","default":"1"}]}"#,
  ] {
    #expect(throws: (any Error).self) { try manifest(invalid) }
  }
}

@Test func extensionSettingsLiveInConfigAndEmptyValuesAreRemoved() throws {
  try withSettings(#"{"extensions":{"window":{"future":"keep"}}}"#) { file in
    try file.set("gap", to: "8", forExtension: "window")
    try file.set("unit", to: "km", forExtension: "units")
    #expect(
      try Configuration.load(at: file.url).extensions == [
        "window": .object(["future": .string("keep"), "gap": .string("8")]),
        "units": .object(["unit": .string("km")]),
      ])
    try file.set("unit", to: nil, forExtension: "units")
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["extensions"]["units"] == .null && json["extensions"]["window"]["gap"] == .string("8"))
    // A malformed extension setting remains repairable without disabling the other settings.
    try Data(#"{"extensions":{"window":{"gap":8}}}"#.utf8).write(to: file.url)
    #expect(try Configuration.load(at: file.url).extensions["window"]?["gap"] == .number(8))
  }
}

@MainActor @Test func everyRequestCarriesTheExtensionsSettingsOverItsDefaults() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "echo", script: "cat > \"\(root.path)/request\"; echo done",
    fields: [
      "settings": [
        ["name": "gap", "type": "number", "description": "Gap", "default": "0"],
        [
          "name": "percent", "type": "number", "description": "Percent", "min": 0, "max": 100, "step": 5,
          "default": 90,
        ],
        ["name": "label", "type": "text", "description": "Label"],
        ["name": "enabled", "type": "bool", "description": "Enabled", "default": "false"],
        [
          "name": "layout", "type": "choice", "description": "Layout",
          "options": ["left", ["value": "right", "label": "Right side"]], "default": "left",
        ],
      ]
    ])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  model.store.change { try $0.set("gap", to: "8", forExtension: "echo") }
  model.store.change { try $0.set("stale", to: "x", forExtension: "echo") }
  model.store.change { try $0.set("enabled", to: "true", forExtension: "echo") }
  model.store.change { try $0.set("layout", to: "right", forExtension: "echo") }
  model.store.change { try $0.set("percent", to: "92", forExtension: "echo") }
  await model.extensions.reload()
  let echo = try #require(model.extensions.commands["extension:echo"])
  _ = try await model.extensions.view(echo, request: ProviderRequest(input: ""))
  let request = try JSONDecoder().decode(
    ProviderRequest.self, from: Data(contentsOf: root.appending(path: "request")))
  #expect(
    request.settings == [
      "gap": .string("8"), "percent": .string("90"), "enabled": .string("true"), "layout": .string("right"),
    ])
}

@MainActor @Test func shadowBannerActionsUseTheLocalCopyAndRestoreBundledSettings() async throws {
  let root = try scratch()
  let files = FileManager.default
  defer { try? files.removeItem(at: root) }
  let local = try extensionFolder(root, name: "window")
  let standalone = try extensionFolder(root, name: "custom")
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  var config = Configuration()
  config.extensions = ["window": .object(["gap": .string("8")])]
  config.providers = [.init("extension:window", enabled: false)]
  config.hotkeys = [
    .init(
      keys: try Shortcut("ctrl+option+left"), target: HotkeyTarget(target: "extension:window", item: "left"))
  ]
  try config.save(at: model.store.url)
  model.store.start(watching: false)
  await model.extensions.reload()
  let host = model.extensions
  let id = "extension:window"
  let location = try #require(host.locations[id])
  let builtIn = try #require(location.bundledFolder)
  #expect(location.shadowsBuiltIn)
  #expect(host.commands[id]?.folder == location.localFolder)
  #expect(!Edition.sameFolder(builtIn, local))
  #expect(host.locations["extension:custom"]?.shadowsBuiltIn == false)
  #expect(host.locations["extension:calculator"]?.shadowsBuiltIn == false)

  var prompts: [String] = []
  var revealed: [URL] = []
  let pane = SettingsPane(
    section: 3, store: model.store, extensions: host,
    clipboard: ClipboardHistory(
      url: root.appending(path: "clipboard-history.json"), pasteboard: FakePasteboard(), interval: nil),
    runs: AgentHistory(url: root.appending(path: "agent-history.json")), updater: nil, pauseHotkey: { _ in },
    canOpenMergeConversation: { !model.agent.busy },
    openMergeConversation: { prompt in
      prompts.append(prompt)
      model.navigator.fill(prompt, newConversation: true)
    },
    revealExtension: { revealed.append($0) })
  pane.showExtensionInFinder(id)
  pane.showExtensionInFinder("extension:custom")
  pane.showExtensionInFinder("extension:calculator")
  #expect(revealed.count == 2)
  #expect(zip(revealed, [local, standalone]).allSatisfy { Edition.sameFolder($0, $1) })

  let prior = FakeAgent()
  model.agent.connect = { _, _, _ in prior }
  model.navigator.send("An earlier conversation")
  #expect(await eventually { prior.running })
  pane.askAgentToMerge(id)
  #expect(prompts.isEmpty && model.agent.busy && !prior.stopped)
  prior.text("The earlier reply")
  prior.end()
  #expect(await eventually { !model.agent.busy && prior.stopped })
  model.navigator.input = "An earlier draft"
  model.agent.connect = { _, _, _ in
    Issue.record("Opening the merge draft must not start an agent")
    throw AgentFailure("The draft was sent")
  }
  pane.askAgentToMerge("extension:custom")
  pane.askAgentToMerge("extension:calculator")
  #expect(prompts.isEmpty)
  pane.askAgentToMerge(id)
  let prompt = try #require(prompts.first)
  #expect(prompts.count == 1)
  #expect(prompt.contains(try #require(location.localFolder).path) && prompt.contains(builtIn.path))
  #expect(prompt.contains("current built-in version") && prompt.contains("my saved settings and hotkeys"))
  #expect(model.navigator.input == prompt)
  #expect(model.agent.active && model.agent.question.isEmpty && !model.agent.busy)

  let localCopy = try #require(host.localCopies[id])
  host.moveToTrash = { _ in throw CocoaError(.fileWriteNoPermission) }
  #expect(throws: CocoaError.self) { try pane.trashExtension(id, confirmed: localCopy) }
  #expect(host.locations[id]?.shadowsBuiltIn == true)
  let trash = root.appending(path: "Trashed extension")
  host.moveToTrash = { try files.moveItem(at: $0, to: trash) }
  let original = try Data(contentsOf: model.store.url)
  try pane.trashExtension(id, confirmed: localCopy)
  #expect(await eventually { host.locations[id]?.source == .bundled })
  #expect(host.commands[id]?.folder == builtIn)
  #expect(host.ownFolder(id) == nil)
  #expect(try String(contentsOf: trash.appending(path: "main.sh"), encoding: .utf8).contains("echo"))
  #expect(try Data(contentsOf: model.store.url) == original)
  await model.finish()
}

@MainActor @Test func onlyTheUsersOwnExtensionsGoToTheTrashIncludingBrokenOnes() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let trash = root.appending(path: "Trash")
  try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
  let host = ExtensionHost(folder: root, bundled: bundledExtensions)
  host.moveToTrash = {
    try FileManager.default.moveItem(at: $0, to: trash.appending(path: $0.lastPathComponent))
  }
  _ = try extensionFolder(root, name: "echo")
  let broken = root.appending(path: "extensions/broken")
  try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
  try Data("{".utf8).write(to: broken.appending(path: "wicket.json"))
  await host.reload()
  #expect(host.problems["extension:broken"] != nil)
  #expect(host.ownFolder("extension:calculator") == nil)
  #expect(throws: ExtensionFailure.self) { try host.trash("extension:calculator") }
  for id in ["extension:echo", "extension:broken"] { try host.trash(id) }
  await host.reload()
  #expect(host.commands["extension:echo"] == nil && host.problems["extension:broken"] == nil)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted() == ["broken", "echo"])
}

@MainActor @Test(arguments: [false, true])
func retiredCopiesCanBeTrashedWithoutMovingUnrelatedFiles(keepItems: Bool) async throws {
  let root = try scratch()
  let files = FileManager.default
  defer { try? files.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  let local = extensions.appending(path: "units")
  let userFile = local.appending(path: "notes.txt")
  let trash = root.appending(path: "Trash")
  try files.createDirectory(at: extensions, withIntermediateDirectories: true)
  try files.createDirectory(at: trash, withIntermediateDirectories: true)
  try files.copyItem(at: fixtureURL("retired-units"), to: local)
  let saved = try JSONEncoder().encode([
    "items": [Row(id: "marathon", title: "Marathon", actions: [.run(Address(input: "42.195 km in mi"))])]
  ])
  if keepItems {
    try saved.write(to: userFile)
    try Data().write(to: local.appending(path: ".DS_Store"))
  }
  let host = ExtensionHost(folder: root, bundled: bundledExtensions)
  let id = "extension:units"
  await host.reload()
  let builtIn = try #require(host.commands[id])
  #expect(builtIn.folder == host.locations[id]?.bundledFolder && host.problems[id] == nil)
  #expect(host.locations[id]?.shadowsBuiltIn == false)
  #expect(host.localCopies[id]?.retired == true)
  #expect(host.ownFolder(id).map { Edition.sameFolder($0, local) } == true)

  if keepItems {
    host.moveToTrash = { _ in throw CocoaError(.fileWriteNoPermission) }
    #expect(throws: CocoaError.self) { try host.trash(id) }
    #expect(
      Set(try files.contentsOfDirectory(atPath: local.path))
        == ["main.py", "notes.txt", "wicket.json", ".DS_Store"])
    #expect(try Data(contentsOf: userFile) == saved)
  }
  host.moveToTrash = {
    try files.moveItem(at: $0, to: trash.appending(path: $0.lastPathComponent))
  }
  try host.trash(id)
  await host.reload()
  #expect(host.ownFolder(id) == nil)
  #expect(host.commands[id] == builtIn && host.problems[id] == nil)
  let trashed = trash.appending(path: "units")
  #expect(Set(try files.contentsOfDirectory(atPath: trashed.path)) == ["main.py", "wicket.json"])
  if keepItems {
    #expect(Set(try files.contentsOfDirectory(atPath: local.path)) == ["notes.txt", ".DS_Store"])
    #expect(try Data(contentsOf: userFile) == saved)
  } else {
    #expect(!files.fileExists(atPath: local.path))
  }

}

@MainActor @Test func trashRefusesACopyThatChangedAfterTheUserConfirmed() async throws {
  let files = FileManager.default
  let root = try scratch()
  defer { try? files.removeItem(at: root) }
  let local = root.appending(path: "extensions/units")
  try files.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
  try files.copyItem(at: fixtureURL("retired-units"), to: local)
  let host = ExtensionHost(folder: root, bundled: bundledExtensions)
  let id = "extension:units"
  await host.reload()
  let confirmed = try #require(host.localCopies[id])
  #expect(confirmed.retired)
  // Repaired into a valid override while the dialog was open.
  try files.removeItem(at: local)
  try files.copyItem(at: bundledExtensions.appending(path: "units"), to: local)
  await host.reload()
  host.moveToTrash = { _ in Issue.record("Nothing should move to the Trash") }
  #expect(throws: ExtensionFailure.self) { try host.trash(id, confirmed: confirmed) }
  #expect(files.fileExists(atPath: local.appending(path: "wicket.json").path))
}

@Test func forgettingAnExtensionRemovesOnlyItsSwitchAndHotkeys() throws {
  try withSettings(
    #"""
    {"future":"keep",
     "providers":[{"id":"apps","enabled":true},{"id":"extension:echo","enabled":false},{"id":"extension:echoes","enabled":false}],
     "extensions":{"echo":{"gap":"8"},"window":{"gap":"4"}},
     "hotkeys":[{"keys":"ctrl+option+e","address":"wicket://echo"},{"keys":"ctrl+option+i","address":"wicket://echo?item=one"},
                {"keys":"ctrl+option+left","address":"wicket://window?item=left"}]}
    """#
  ) { file in
    try file.forget(extension: "echo")
    let config = try Configuration.load(at: file.url)
    #expect(config.providers.map(\.id) == ["apps", "extension:echoes"])
    #expect(config.extensions["echo"]?["gap"] == .string("8"))
    #expect(config.extensions["window"]?["gap"] == .string("4"))
    #expect(config.hotkeys.map(\.target) == [HotkeyTarget(target: "extension:window", item: "left")])
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["future"] == .string("keep"))
    // Nothing kept for it: the file is left as it was, with no keys added.
    try Data("{}".utf8).write(to: file.url)
    try file.forget(extension: "echo")
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url)) == .object([:]))
  }
}

@MainActor @Test(arguments: [0.75, 0.15])
func theSliderSavesEveryTransparencyExactly(value: Double) throws {
  // An untouched old file stores this value but reads as 0.5, so choosing it is a change to save.
  for json in ["{}", #"{"backgroundTransparency":\#(value)}"#] {
    try withSettings(json) { file in
      var slider = SliderEdit("backgroundTransparency")
      slider.value = value
      slider.editingChanged(false, store: ConfigurationStore(url: file.url))
      let saved = try Configuration.load(at: file.url)
      #expect(saved.backgroundTransparency == value)
    }
  }
}

@Test func anEditThatChangesNothingLeavesTheFileUntouched() throws {
  for json in [#"{ "backgroundTransparency": 0.75 }"#, #"{ "blur": 4 }"#] {
    try withSettings(json) { file in
      try file.bind(nil, to: HotkeyTarget(target: "extension:window", item: "left"))
      #expect(try String(contentsOf: file.url, encoding: .utf8) == json)
    }
  }
}

@Test func theFirstSaveOfAnOldFileKeepsWhatItReadsAs() throws {
  // An old look's default goes, as it read as unset; another value stays. Either way `blur` marks the file
  // as current, so a 0.75 saved later is kept.
  try withSettings(#"{"backgroundTransparency":0.75}"#) { file in
    try file.set("enabled", to: false, in: "voice")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
    #expect(object?["backgroundTransparency"] == nil && object?["blur"] as? Double == 4)
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.5)
    try file.set("backgroundTransparency", to: 0.75)
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.75)
  }
  try withSettings(#"{"backgroundTransparency":0.4,"blur":4}"#) { file in
    try file.set("enabled", to: false, in: "voice")
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.4)
  }
  try withSettings(#"{"backgroundTransparency":0.4}"#) { file in
    try file.set("enabled", to: false, in: "voice")
    #expect(try Configuration.load(at: file.url).backgroundTransparency == 0.4)
  }
}

@MainActor @Test func anUnreadableFileAtStartRunsNoExtensionUntilAValidOneLoads() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  await model.extensions.reload()
  // The file may switch the calculator off, but it no longer reads: the defaults must not switch it on.
  try Data(#"{"providers":[{"id":"extension:calculator","enabled":false}],"#.utf8)
    .write(to: model.store.url)
  model.store.start(watching: false)
  #expect(model.problem?.hasPrefix("Config:") == true)
  model.navigator.input = "2+2"
  await model.navigator.settled()
  #expect(!model.navigator.results.contains { $0.provider == "extension:calculator" })
  model.navigator.go(Address(extensionName: "calculator"), submitted: true)
  await model.navigator.settled()
  #expect(model.navigator.command?.problem?.contains("switched off") == true)
  #expect(model.navigator.escape())
  model.navigator.input = "3+3"
  await model.navigator.settled()
  #expect(!model.navigator.results.contains { $0.provider == "extension:calculator" })
  // Once a valid file loads, it decides, and what is shown follows it without another keystroke.
  try Data("{}".utf8).write(to: model.store.url)
  model.store.load()
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["extension:calculator"])
  await model.finish()
}

@MainActor @Test func aSymlinkedConfigIsEditedAndWatchedWhereItPoints() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appending(path: "dotfiles/wicket.json")
  try FileManager.default.createDirectory(
    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("{}".utf8).write(to: target)
  let link = root.appending(path: "config/config.json")
  try FileManager.default.createDirectory(
    at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let store = ConfigurationStore(url: link)
  store.start()
  #expect(store.change { try $0.set("textSize", to: "large") })
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
  #expect(try Configuration.load(at: target).textSize == .large && store.configuration.textSize == .large)
  // An edit where the link points reloads, once the events of the setup have passed.
  try await Task.sleep(for: .milliseconds(500))
  try Data(#"{"textSize":"small"}"#.utf8).write(to: target, options: .atomic)
  #expect(await eventually { store.configuration.textSize == .small })
}

@Test func settingsReapplyAnEditWhenTheFileChangesDuringTheSave() throws {
  try withSettings(#"{"extensions":{"window":{"gap":"0"}}}"#) { file in
    var attempts = 0
    let configuration = try file.edit { object in
      var extensions = object["extensions"] as? [String: [String: String]] ?? [:]
      extensions["window", default: [:]]["gap"] = "8"
      object["extensions"] = extensions
      attempts += 1
      if attempts == 1 {
        let external = #"{"extensions":{"window":{"gap":"0","almostMaximize":"80"}},"future":true}"#
        try Data(external.utf8).write(to: file.url, options: .atomic)
      }
    }
    #expect(attempts == 2)
    #expect(
      configuration.extensions["window"] == .object(["gap": .string("8"), "almostMaximize": .string("80")]))
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["future"] == .bool(true))
  }
}

@Test func overlappingSettingsSavesUseTheSameLockThroughASymlink() throws {
  try withSettings { file in
    let alias = file.url.deletingLastPathComponent().appending(path: "alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file.url)
    let firstEditing = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondCalling = DispatchSemaphore(value: 0)
    let secondEditing = DispatchSemaphore(value: 0)
    let saves = DispatchGroup()
    defer {
      releaseFirst.signal()
      _ = saves.wait(timeout: .now() + .seconds(5))
    }
    DispatchQueue.global().async(group: saves) {
      do {
        try file.edit { object in
          firstEditing.signal()
          guard releaseFirst.wait(timeout: .now() + .seconds(5)) == .success else {
            throw CocoaError(.fileWriteUnknown)
          }
          object["resultsOnlyWhenTyping"] = true
        }
      } catch { Issue.record(error) }
    }
    try #require(firstEditing.wait(timeout: .now() + .seconds(5)) == .success)
    DispatchQueue.global().async(group: saves) {
      do {
        secondCalling.signal()
        try ConfigurationFile(url: alias).edit { object in
          secondEditing.signal()
          #expect(object["resultsOnlyWhenTyping"] as? Bool == true)
          object["backgroundTransparency"] = 0.75
        }
      } catch { Issue.record(error) }
    }
    try #require(secondCalling.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(secondEditing.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
    releaseFirst.signal()
    try #require(saves.wait(timeout: .now() + .seconds(5)) == .success)
    let updated = try Configuration.load(at: file.url)
    #expect(updated.resultsOnlyWhenTyping && updated.backgroundTransparency == 0.75)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == file.url.path)
  }
}
