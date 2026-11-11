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

@Test func configPersistence() throws {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/config.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  try Configuration().save(at: url)
  #expect(try Configuration.load(at: url) == Configuration())
}

@Test func omittedSourcesTakeTheirDefaultAndFollowTheList() {
  var config = Configuration()
  config.providers = [.init("extension:b", enabled: false), .init("math"), .init("files", enabled: false)]
  let sources = config.sources(extensions: ["extension:z", "extension:b", "extension:a"])
  #expect(
    sources == [
      .init("extension:b", enabled: false), .init("math"), .init("files", enabled: false), .init("apps"),
      .init("clipboard", enabled: false), .init("extension:a"), .init("extension:z"),
    ])
  #expect(
    config.isEnabled("extension:a", extensions: ["extension:a"])
      && !config.isEnabled("extension:b", extensions: ["extension:b"]))
  // A config written before file search existed gets it.
  config.providers = [.init("math"), .init("apps")]
  #expect(config.isEnabled("files", extensions: []))
}
