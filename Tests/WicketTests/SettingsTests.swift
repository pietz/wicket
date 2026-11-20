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
  store.onChange = { _, problem in launcherProblem = problem }
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
    #expect(store.hotkeyProblem != nil && hotkey.inEffect == .default)
    #expect(try Data(contentsOf: file.url) == original)
    for spelling in ["cmd+c", "cmd+v", "cmd+q", "cmd+w", "cmd+shift+z", "cmd+k"] {
      let count = attempted.count
      store.setHotkey(try Shortcut(spelling))
      #expect(store.hotkeyProblem?.contains("editing or app shortcut") == true)
      #expect(attempted.count == count)
      #expect(try Data(contentsOf: file.url) == original)
    }
    store.setHotkey(try Shortcut("ctrl+j"))
    #expect(store.hotkeyProblem == nil)
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

@MainActor @Test func webSearchIsAnOptionalExampleAndExistingInstallsArePreserved() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  let web = root.appending(path: "extensions/web-search")
  #expect(!FileManager.default.fileExists(atPath: web.path))
  #expect(
    FileManager.default.fileExists(atPath: root.appending(path: "examples/web-search/wicket.json").path))
  // Units ships inside the app now (`ExtensionHost.bundled`), so nothing is installed into extensions.
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "extensions").path).isEmpty)
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "examples/currency/main.py").path))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "examples").path).sorted() == [
      "currency", "quicklinks", "web-search",
    ])
  try FileManager.default.copyItem(at: root.appending(path: "examples/web-search"), to: web)
  let marker = web.appending(path: "user-file")
  try Data("keep".utf8).write(to: marker)
  try ExtensionHost.installFiles(in: root)
  #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
}

// MARK: - Extension settings

@Test func aManifestDeclaresSettingsLikeArgumentsWithDefaults() throws {
  func manifest(_ json: String) throws -> ExtensionManifest {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
  }
  let window = try manifest(
    #"{"name":"W","description":"Moves windows.","command":["./main"],"settings":[{"name":"gap","placeholder":"Gap","default":"0"},{"name":"note"}]}"#
  )
  #expect(window.description == "Moves windows." && window.settings.map(\.name) == ["gap", "note"])
  #expect(window.settings[0].default == "0" && window.settings[1].placeholder == nil)
  for invalid in [
    #"{"name":"W","command":["x"],"settings":[{"name":"a"},{"name":"a"}]}"#,
    #"{"name":"W","command":["x"],"settings":[{"name":""}]}"#,
    #"{"name":"W","items":[],"settings":[{"name":"a"}]}"#,
    #"{"name":"W","command":["x"],"arguments":[{"name":"a","default":"1"}]}"#,
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
        "window": ["future": "keep", "gap": "8"], "units": ["unit": "km"],
      ])
    try file.set("unit", to: nil, forExtension: "units")
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["extensions"]["units"] == .null && json["extensions"]["window"]["gap"] == .string("8"))
    // Values are strings, as arguments are.
    try Data(#"{"extensions":{"window":{"gap":8}}}"#.utf8).write(to: file.url)
    #expect(throws: (any Error).self) { try Configuration.load(at: file.url) }
  }
}

@MainActor @Test func everyRequestCarriesTheExtensionsSettingsOverItsDefaults() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "echo", script: "cat > \"\(root.path)/request\"; echo done",
    fields: [
      "settings": [
        ["name": "gap", "default": "0"], ["name": "percent", "default": "90"], ["name": "label"],
      ]
    ])
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  model.store.change { try $0.set("gap", to: "8", forExtension: "echo") }
  model.store.change { try $0.set("stale", to: "x", forExtension: "echo") }
  await model.extensions.reload()
  let echo = try #require(model.extensions.commands["extension:echo"])
  _ = try await model.extensions.view(echo, request: ProviderRequest(input: ""))
  let request = try JSONDecoder().decode(
    ProviderRequest.self, from: Data(contentsOf: root.appending(path: "request")))
  #expect(request.settings == ["gap": "8", "percent": "90"])
}

@MainActor @Test func makeItMineCopiesABundledExtensionThatThenShadowsIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let host = ExtensionHost(folder: root, bundled: bundledExtensions)
  await host.reload()
  let window = try #require(host.commands["extension:window"])
  #expect(host.isBundled(window))
  try host.makeMine(window)
  await host.reload()
  let mine = try #require(host.commands["extension:window"])
  #expect(
    !host.isBundled(mine)
      && mine.folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path)
      && mine.manifest == window.manifest)
  #expect(FileManager.default.isExecutableFile(atPath: mine.folder.appending(path: "main").path))
  // A folder of that name is never replaced.
  #expect(throws: ExtensionFailure.self) { try host.makeMine(window) }
}

@MainActor @Test func onlyTheUsersOwnExtensionsGoToTheTrashBrokenAndShadowingOnesIncluded() async throws {
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
  try host.makeMine(try #require(host.commands["extension:window"]))
  await host.reload()
  #expect(host.problems["extension:broken"] != nil)
  #expect(host.ownFolder("extension:calculator") == nil)
  #expect(throws: ExtensionFailure.self) { try host.trash("extension:calculator") }
  #expect(!host.hasBundled("echo") && host.hasBundled("window"))
  for id in ["extension:echo", "extension:broken", "extension:window"] { try host.trash(id) }
  await host.reload()
  #expect(host.commands["extension:echo"] == nil && host.problems["extension:broken"] == nil)
  // The bundled window comes back in place of the user's copy.
  #expect(try host.isBundled(#require(host.commands["extension:window"])))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted() == ["broken", "echo", "window"])
}

@Test func forgettingAnExtensionRemovesOnlyItsSwitchSettingsAndHotkeys() throws {
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
    #expect(config.extensions == ["window": ["gap": "4"]])
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
