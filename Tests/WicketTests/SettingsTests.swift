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
    try file.set("microphone", to: "stable-uid", in: "voice")
    #expect(try Configuration.load(at: file.url).voice.microphone == "stable-uid")
    try file.set("microphone", to: nil, in: "voice")
    #expect(try Configuration.load(at: file.url).voice.microphone == nil)
    try file.set("model", to: "sonnet", in: "agent")
    try file.setProvider("apps", enabled: false)
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["future"] == .object("list", .array([.number(1), .bool(true), .string("x")])))
    #expect(json["voice"]["future"] == .number(42))
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
    try file.setProvider("math", enabled: false)
    try file.setProvider("extension:new", enabled: true)
    let config = try Configuration.load(at: file.url)
    #expect(config.hotkey == (try Shortcut("ctrl+option+k")))
    #expect(config.backgroundTransparency == 0.65 && !config.voice.enabled)
    #expect(config.agent.agent == .codex && config.agent.model == "gpt-6")
    #expect(config.agent.effort == "high" && config.agent.mode == "workspace-write")
    #expect(
      config.providers == [
        .init("math", enabled: false), .init("apps"), .init("files"), .init("extension:new"),
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  #expect(model.problem == nil)
  model.actionProblem = "paste"
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
  model.clearTransientProblems()
  #expect(model.problem == "hotkey")
  model.store.hotkeyProblem = nil
  #expect(model.problem == "install")
}

@MainActor @Test func settingsHotkeyConflictUsesExistingRegistrationResult() throws {
  final class Handle {}
  let hotkey = PaletteHotKey { shortcut in shortcut.key == "k" ? nil : Handle() }
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
    var slider = TransparencyEdit()
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
    final class Handle {}
    let store = ConfigurationStore(url: file.url)
    let original = try Data(contentsOf: file.url)
    var attempted: [Shortcut] = []
    let hotkey = PaletteHotKey { shortcut in
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
    final class Handle {}
    let store = ConfigurationStore(url: file.url)
    let hotkey = PaletteHotKey { _ in Handle() }
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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  var opened = 0
  model.onSettings = { opened += 1 }
  model.input = "Settings"
  #expect(model.results.map(\.provider) == ["settings", "agent"])
  #expect(model.selected?.row.title == "Settings" && model.activateReturn())
  #expect(opened == 1 && !model.agent.active)
  model.input = "unmatched sentence"
  #expect(model.results.first?.provider == "agent")
  await model.finish()
}

@Test func switchingASourceKeepsItsPositionOtherEntriesAndUnknownFields() throws {
  try withSettings(#"{"providers":[{"id":"apps","enabled":false,"future":42},{"id":"math","enabled":true}]}"#)
  { file in
    try file.setProvider("apps", enabled: true)
    try file.setProvider("extension:new", enabled: false)
    #expect(
      try Configuration.load(at: file.url).providers == [
        .init("apps"), .init("math"), .init("extension:new", enabled: false),
      ])
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file.url))
    #expect(json["providers"].array[0]["future"] == .number(42))
  }
}

@MainActor @Test func webSearchIsAnOptionalExampleAndExistingInstallsArePreserved() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  let web = root.appending(path: "extensions/web-search")
  #expect(!FileManager.default.fileExists(atPath: web.path))
  #expect(
    FileManager.default.fileExists(atPath: root.appending(path: "examples/web-search/wicket.json").path))
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "extensions/units/wicket.json").path))
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "examples/currency/main.py").path))
  try FileManager.default.copyItem(at: root.appending(path: "examples/web-search"), to: web)
  let marker = web.appending(path: "user-file")
  try Data("keep".utf8).write(to: marker)
  try ExtensionHost.installFiles(in: root)
  #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
}
