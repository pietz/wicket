import Foundation
import Testing

@testable import WicketApp

private func config(_ json: String) throws -> Configuration {
  try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
}

@Test func defaultsAndPartialConfig() throws {
  #expect(try config("{}") == Configuration())
  #expect(Shortcut.default == (try Shortcut("option+space")))
  #expect(Shortcut.default.keyCode == 49 && Shortcut.default.modifiers == .option)
  #expect(Shortcut.default.symbols == "⌥Space")
  let changed = try config(#"{"backgroundTransparency":0.4}"#)
  #expect(changed.hotkey == .default)
  #expect(changed.backgroundTransparency == 0.4)
  // Files from before the clear glass (no `blur`) with an earlier look's default get the current one;
  // newer files keep every value.
  #expect(try config(#"{"backgroundTransparency":0.15}"#).backgroundTransparency == 0.5)
  #expect(try config(#"{"backgroundTransparency":0.75}"#).backgroundTransparency == 0.5)
  #expect(try config(#"{"backgroundTransparency":0.75,"blur":4}"#).backgroundTransparency == 0.75)
  #expect(try config(#"{"backgroundTransparency":0.15,"blur":4}"#).backgroundTransparency == 0.15)
  var saved = Configuration()
  saved.backgroundTransparency = 0.75
  #expect(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(saved)) == saved)
}

@Test func explicitOrderAndDisable() throws {
  let parsed = try config(
    #"{"providers":[{"id":"apps","enabled":false},{"id":"math","enabled":true}]}"#)
  #expect(parsed.providers.map(\.id) == ["apps", "math"])
  #expect(!parsed.providers[0].enabled)
  #expect(try config(#"{"providers":[]}"#).providers.isEmpty)
  #expect(
    try config(#"{"providers":[{"id":"future","enabled":true}]}"#).providers[0].id == "future")
}

@Test(arguments: [
  #"{"hotkey":"space"}"#, #"{"hotkey":"shift+a"}"#, #"{"hotkey":"hyper+space"}"#,
  #"{"backgroundTransparency":-0.1}"#, #"{"backgroundTransparency":1.1}"#,
  #"{"blur":-1}"#, #"{"blur":10.5}"#, #"{"appearance":"sepia"}"#,
  #"{"providers":[{"id":"apps","enabled":true},{"id":"apps","enabled":false}]}"#,
  #"{"providers":[{"id":"","enabled":true}]}"#, #"{"providers":false}"#, "{",
])
func invalidConfig(json: String) { #expect(throws: (any Error).self) { try config(json) } }

// Shortcut cases carried over from the first Wicket's SettingsTests.
@Test(arguments: [
  ("opt+space", 49, 0x800), ("Cmd + Shift + K", 40, 0x300), ("f13", 105, 0), ("ctrl+;", 41, 0x1000),
])
func shortcutParsing(spelling: String, code: Int, modifiers: Int) throws {
  let shortcut = try Shortcut(spelling)
  #expect(shortcut.keyCode == code)
  #expect(shortcut.modifiers.rawValue == modifiers)
}

@Test(arguments: ["", "option+", "option+spacebar", "ctrl+option", "option+a+b"])
func invalidShortcut(spelling: String) {
  #expect(throws: Shortcut.ParseError.self) { try Shortcut(spelling) }
}

@MainActor @Test(arguments: [false, true]) func firstLaunchStoresOnlyTheDetectedAgent(codexOnly: Bool) throws
{
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/config.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = ConfigurationStore(url: url)
  store.start(watching: false, installed: { codexOnly && $0 == .codex })
  let expected: JSONValue = codexOnly ? .object("agent", .object("name", .string("codex"))) : .object([:])
  #expect(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) == expected)
  var effective = Configuration()
  if codexOnly { effective.agent.agent = .codex }
  #expect(store.configuration == effective)
}

@Test func omittedSourcesTakeTheirDefaultAndFollowTheList() {
  var config = Configuration()
  config.providers = [
    .init("extension:b", enabled: false), .init("math"), .init("files", enabled: false),
    .init("extension:gone"),
  ]
  let sources = config.sources(extensions: ["extension:z", "extension:b", "extension:a"])
  // An entry for a source that is gone (math from when the calculator was built in, a deleted extension) is no source.
  #expect(
    sources == [
      .init("extension:b", enabled: false), .init("files", enabled: false), .init("apps"),
      .init("clipboard", enabled: false), .init("extension:a"), .init("extension:z"),
    ])
  #expect(
    config.isEnabled("extension:a", extensions: ["extension:a"])
      && !config.isEnabled("extension:b", extensions: ["extension:b"]))
  // A config written before file search existed gets it.
  config.providers = [.init("apps")]
  #expect(config.isEnabled("files", extensions: []))
}

/// The launcher hotkey is the way to the error, so a file that is broken at launch still hands the app a
/// configuration to register: the defaults, without extensions.
@MainActor @Test func aBrokenFileAtLaunchStillReportsAConfiguration() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "config.json")
  try Data(#"{"hotkey":"space"}"#.utf8).write(to: url)
  let store = ConfigurationStore(url: url)
  var reported: [Configuration] = []
  store.onChange = { reported.append($0) }
  store.start(watching: false)
  #expect(store.problem?.hasPrefix("Config:") == true)
  #expect(reported.count == 1 && reported[0].hotkey == .default && reported[0].hotkeys.isEmpty)
  #expect(!reported[0].runsExtensions)
}

/// A linked config.json whose target is missing at launch is broken, not absent: the link stays and no
/// extension runs on defaults.
@MainActor @Test func aDanglingConfigLinkIsBrokenNotReplaced() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "config.json")
  let target = root.appending(path: "elsewhere/config.json").path
  try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
  let store = ConfigurationStore(url: url)
  store.start(watching: false)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target)
  #expect(store.problem != nil && !store.configuration.runsExtensions)
}
