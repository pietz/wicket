import Carbon.HIToolbox
import Foundation
import Testing

@testable import WicketCore

@Test func shellSettingsFailIndependentlyAndPreserveUnknownKeys() throws {
    let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    let invalid = try decode(#"{"shell":{"prefix":"ai", "destination":"terminal"}}"#)
    #expect(invalid.shell.prefix == ">")
    #expect(invalid.shell.destination == .terminal)
    #expect(invalid.ignored.count == 1)
    let other = try decode(#"{"shell":{"prefix":"$", "destination":false}}"#)
    #expect(other.shell.prefix == "$")
    #expect(other.shell.destination == .wicket)
    #expect(other.ignored.count == 1)
    let url = temporarySettingsURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try write(#"{"shell":{"future":42}}"#, to: url)
    try Settings.update(at: url) {
        $0.shell.prefix = ">>"
        $0.shell.destination = .terminal
    }
    #expect(try Settings.load(from: url).shell.prefix == ">>")
    #expect(try Settings.load(from: url).shell.destination == .terminal)
    try Settings.update(at: url) { $0.shell = Settings.Shell() }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect((object?["shell"] as? [String: Int]) == ["future": 42])
}

@Test(arguments: [
    ("option+space", kVK_Space, optionKey),
    ("opt+space", kVK_Space, optionKey),
    ("alt+space", kVK_Space, optionKey),
    ("ctrl+option+space", kVK_Space, controlKey | optionKey),
    ("option+ctrl+space", kVK_Space, controlKey | optionKey),
    ("space+option", kVK_Space, optionKey),
    ("cmd+shift+k", kVK_ANSI_K, cmdKey | shiftKey),
    ("Cmd + Shift + K", kVK_ANSI_K, cmdKey | shiftKey),
    ("control+command+0", kVK_ANSI_0, controlKey | cmdKey),
    ("option+option+space", kVK_Space, optionKey),
    ("f13", kVK_F13, 0),
    ("ctrl+;", kVK_ANSI_Semicolon, controlKey),
    ("cmd+escape", kVK_Escape, cmdKey),
])
func parsesValidSpellings(spelling: String, keyCode: Int, modifiers: Int) throws {
    let shortcut = try Shortcut(spelling)
    #expect(shortcut.keyCode == keyCode)
    #expect(shortcut.modifiers.rawValue == modifiers)
}

@Test(arguments: [
    ("", Shortcut.ParseError.unknown("")),
    ("option+", .unknown("")),
    ("option+spacebar", .unknown("spacebar")),
    ("hyper+space", .unknown("hyper")),
    ("ctrl+option", .missingKey),
    ("option+a+b", .multipleKeys("a", "b")),
])
func rejectsInvalidSpellings(spelling: String, error: Shortcut.ParseError) {
    #expect(throws: error) { try Shortcut(spelling) }
}

@Test func describesCanonically() throws {
    #expect(try Shortcut("cmd+shift+opt+ctrl+k").description == "ctrl+option+shift+cmd+k")
    #expect(Shortcut.default.description == "option+space")
}

/// The key code table is written out by hand so WicketCore stays Foundation-only; check it against
/// Carbon's constants.
@Test func keyCodesMatchCarbon() {
    let letters = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    let digits = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9,
    ]
    let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    var expected: [String: Int] = [
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "]": kVK_ANSI_RightBracket, "[": kVK_ANSI_LeftBracket,
        "'": kVK_ANSI_Quote, ";": kVK_ANSI_Semicolon, "\\": kVK_ANSI_Backslash, ",": kVK_ANSI_Comma,
        "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, "`": kVK_ANSI_Grave,
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape,
    ]
    for (i, code) in letters.enumerated() { expected[String(UnicodeScalar(UInt8(97 + i)))] = code }
    for (i, code) in digits.enumerated() { expected[String(i)] = code }
    for (i, code) in functionKeys.enumerated() { expected["f\(i + 1)"] = code }
    #expect(Shortcut.keyCodes == expected)
}

@Test func settingsDefaultWhenFileMissing() throws {
    let url = URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-\(UUID())/settings.json")
    #expect(try Settings.load(from: url) == Settings())
    #expect(Settings().hotkey == .default)
}

@Test func settingsDecode() throws {
    let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    #expect(try decode(#"{"hotkey": "ctrl+option+space"}"#).hotkey == Shortcut("ctrl+option+space"))
    #expect(try decode(#"{"hotkey": "cmd+k", "future": {"x": 1}}"#).hotkey == Shortcut("cmd+k"))
    #expect(try decode("{}") == Settings())
    #expect(try decode(#"{"hotkey": null}"#) == Settings())
    #expect(throws: DecodingError.self) { try decode("not json") }
}

/// A bad hotkey is ignored on its own, like every other field: the rest of the file still applies
/// and the palette keeps the default hotkey, so Wicket can still be summoned.
@Test(arguments: [
    (
        #"{"hotkey": "option+spacebar"}"#,
        #"hotkey: "option+spacebar": unknown key or modifier "spacebar"; using option+space"#
    ),
    (#"{"hotkey": 1}"#, "hotkey: Expected to decode String but found number instead.; using option+space"),
    (#"{"hotkey": "shift+k"}"#, "hotkey needs cmd, ctrl or option (or an F-key); using option+space"),
])
func badHotkeyFallsBackAlone(json: String, reason: String) throws {
    let object = String(json.dropLast()) + #", "paletteWidth": 720}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(object.utf8))
    #expect(settings.hotkey == .default)
    #expect(settings.paletteWidth == 720)
    #expect(settings.ignored == [reason])
}

@Test(arguments: [
    (#"{}"#, 600.0, false),
    (#"{"paletteWidth": 720}"#, 720, false),
    (#"{"paletteWidth": 480}"#, 480, false),
    (#"{"paletteWidth": 900.5}"#, 600, true),
    (#"{"paletteWidth": 100}"#, 600, true),
    (#"{"paletteWidth": "wide"}"#, 600, true),
    (#"{"paletteWidth": null}"#, 600, true),
])
func paletteWidthFallsBackAlone(json: String, width: Double, ignored: Bool) throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.paletteWidth == width)
    #expect(settings.ignored == (ignored ? ["paletteWidth must be a number from 480 to 900; using 600"] : []))
}

@Test func settingsDirectory() {
    #expect(Settings.directory(environment: ["WICKET_CONFIG_DIR": "/tmp/w"]).path == "/tmp/w")
    #expect(Settings.directory(environment: [:]).path.hasSuffix("/.config/wicket"))
}

@Test func recordsShortcutsFromKeyPresses() {
    #expect(Shortcut(keyCode: kVK_Space, modifiers: .option) == .default)
    #expect(Shortcut(keyCode: kVK_ANSI_K, modifiers: [.command, .shift])?.description == "shift+cmd+k")
    #expect(Shortcut(keyCode: kVK_F13, modifiers: [])?.description == "f13")
    #expect(Shortcut(keyCode: kVK_ANSI_A, modifiers: []) == nil)
    #expect(Shortcut(keyCode: kVK_ANSI_A, modifiers: .shift) == nil)
    #expect(Shortcut(keyCode: kVK_ANSI_KeypadClear, modifiers: .command) == nil)
}

@Test func showsSymbols() throws {
    #expect(try Shortcut("cmd+shift+opt+ctrl+k").symbols == "⌃⌥⇧⌘K")
    #expect(Shortcut.default.symbols == "⌥Space")
    #expect(try Shortcut("f5").symbols == "F5")
}

/// A fresh settings.json path in a folder that does not exist yet.
private func temporarySettingsURL() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-\(UUID())/settings.json")
}

private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
}

@Test func updateCreatesMissingFileWithCurrentValues() throws {
    let url = temporarySettingsURL()
    try Settings.update(at: url) { _ in }
    #expect(try read(url) == "{\n  \"hotkey\" : \"option+space\",\n  \"paletteWidth\" : 600\n}\n")
}

@Test func updateKeepsUnknownFields() throws {
    let url = temporarySettingsURL()
    try write(#"{"zeta": [1, "x/y"], "hotkey": "opt+space", "future": {"on": true}}"#, to: url)
    try Settings.update(at: url) { $0.hotkey = try! Shortcut("ctrl+option+space") }
    #expect(
        try read(url) == """
            {
              "future" : {
                "on" : true
              },
              "hotkey" : "ctrl+option+space",
              "zeta" : [
                1,
                "x/y"
              ]
            }

            """)
    #expect(try Settings.load(from: url).hotkey == Shortcut("ctrl+option+space"))
}

@Test func updateLeavesFileAloneWhenNothingChanges() throws {
    let url = temporarySettingsURL()
    let json = #"{"hotkey":"alt+space", "x": 1}"#
    try write(json, to: url)
    try Settings.update(at: url) { $0.hotkey = .default }
    #expect(try read(url) == json)
}

@Test func updateNeverOverwritesInvalidFile() throws {
    let url = temporarySettingsURL()
    for json in ["not json", #"{"hotkey": "cmd+k", "x": 1"#, "[1]"] {
        try write(json, to: url)
        #expect(throws: Settings.InvalidFile.self) { try Settings.update(at: url) { $0.hotkey = .default } }
        #expect(throws: Settings.InvalidFile.self) { try Settings.load(from: url) }
        #expect(try read(url) == json)
    }
}

@Test func invalidFileExplainsWhy() throws {
    let url = temporarySettingsURL()
    try write(#"{"commands": {}, "hotkey": "cmd+k""#, to: url)
    #expect(throws: Settings.InvalidFile(description: "The given data was not valid JSON.")) {
        try Settings.load(from: url)
    }
}

@Test(arguments: [
    (#"{}"#, nil, nil),
    (#"{"ai": {"provider": "claude"}}"#, AgentProvider.claude, nil),
    (#"{"ai": {"provider": "codex", "future": 1}}"#, .codex, nil),
    (#"{"ai": {"provider": null}}"#, nil, nil),
    (#"{"ai": null}"#, nil, nil),
    (
        #"{"ai": {"provider": "gemini"}}"#, nil,
        #"ai.provider must be "claude" or "codex"; using the first one that's ready"#
    ),
    (
        #"{"ai": {"provider": 1}}"#, nil,
        #"ai.provider must be "claude" or "codex"; using the first one that's ready"#
    ),
    (#"{"ai": "codex"}"#, nil, "ai must be an object; using defaults"),
])
func aiProviderFallsBackAlone(json: String, provider: AgentProvider?, ignored: String?) throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.ai.provider == provider)
    #expect(settings.ignored == (ignored.map { [$0] } ?? []))
}

@Test func updateSetsAndClearsTheProviderKeepingUnknownKeys() throws {
    let url = temporarySettingsURL()
    try write(#"{"hotkey": "opt+space", "ai": {"model": "fast"}}"#, to: url)
    try Settings.update(at: url) { $0.ai.provider = .claude }
    #expect(try Settings.load(from: url).ai.provider == .claude)
    #expect(try read(url).contains(#""model" : "fast""#))
    // The hotkey's spelling is the file's: only what changed is written.
    #expect(try read(url).contains(#""hotkey" : "opt+space""#))

    try Settings.update(at: url) { $0.ai.provider = nil }
    #expect(
        try read(url) == """
            {
              "ai" : {
                "model" : "fast"
              },
              "hotkey" : "opt+space"
            }

            """)

    // None chosen again with nothing else in the object: the object goes too.
    try write(#"{"ai": {"provider": "codex"}}"#, to: url)
    try Settings.update(at: url) { $0.ai.provider = nil }
    #expect(try read(url) == "{\n\n}\n")
}

/// A bad value is reported, not fixed: the file keeps it while other fields change, until the field
/// itself is set.
@Test func updateKeepsAnIgnoredValueUntilItIsSet() throws {
    let cases: [(String, String, (inout Settings) -> Void, (Settings) -> Bool)] = [
        (
            #"{"hotkey": "option+spacebar"}"#, #""hotkey" : "option+spacebar""#,
            { $0.hotkey = try! Shortcut("cmd+k") },
            { $0.hotkey == (try! Shortcut("cmd+k")) }
        ),
        (
            #"{"paletteWidth": "wide"}"#, #""paletteWidth" : "wide""#, { $0.paletteWidth = 720 },
            { $0.paletteWidth == 720 }
        ),
        (
            #"{"ai": {"provider": "gemini"}}"#, #""provider" : "gemini""#, { $0.ai.provider = .codex },
            { $0.ai.provider == .codex }
        ),
    ]
    for (json, kept, set, applied) in cases {
        let url = temporarySettingsURL()
        try write(json, to: url)
        try Settings.update(at: url) { $0.textSize = .large }
        #expect(try read(url).contains(kept))
        try Settings.update(at: url, set)
        #expect(applied(try Settings.load(from: url)))
    }
}

@Test(arguments: [
    (#"{}"#, true, false),
    (#"{"showInMenuBar": false}"#, false, false),
    (#"{"showInMenuBar": true}"#, true, false),
    (#"{"showInMenuBar": null}"#, true, false),
    (#"{"showInMenuBar": "no"}"#, true, true),
])
func showInMenuBarFallsBackAlone(json: String, show: Bool, ignored: Bool) throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.showInMenuBar == show)
    #expect(
        settings.ignored
            == (ignored ? ["showInMenuBar must be true or false; showing the menu bar icon"] : []))
}

/// Hiding the icon writes `false`; showing it again removes the field, so the file stays minimal.
@Test func updateWritesShowInMenuBarOnlyWhenHidden() throws {
    let url = temporarySettingsURL()
    try write(#"{"hotkey": "cmd+k"}"#, to: url)
    try Settings.update(at: url) { $0.showInMenuBar = false }
    #expect(try read(url).contains(#""showInMenuBar" : false"#))
    #expect(try Settings.load(from: url).showInMenuBar == false)
    try Settings.update(at: url) { $0.showInMenuBar = true }
    #expect(try read(url) == "{\n  \"hotkey\" : \"cmd+k\"\n}\n")
}

@Test(arguments: [
    (#"{}"#, TextSize.medium, false),
    (#"{"textSize": "small"}"#, .small, false),
    (#"{"textSize": "larger"}"#, .larger, false),
    (#"{"textSize": null}"#, .medium, false),
    (#"{"textSize": "huge"}"#, .medium, true),
    (#"{"textSize": 15}"#, .medium, true),
])
func textSizeFallsBackAlone(json: String, size: TextSize, ignored: Bool) throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.textSize == size)
    #expect(
        settings.ignored == (ignored ? ["textSize must be small, medium, large or larger; using medium"] : [])
    )
}

/// Small is the original look (body 13); each step adds two points.
@Test func textSizeSteps() {
    #expect(TextSize.allCases.map(\.bodySize) == [13, 15, 17, 19])
}

/// A non-default size is written; the default removes the field, so the file stays minimal.
@Test func updateWritesTextSizeOnlyWhenChanged() throws {
    let url = temporarySettingsURL()
    try write(#"{"hotkey": "cmd+k"}"#, to: url)
    try Settings.update(at: url) { $0.textSize = .large }
    #expect(try read(url).contains(#""textSize" : "large""#))
    #expect(try Settings.load(from: url).textSize == .large)
    try Settings.update(at: url) { $0.textSize = .medium }
    #expect(try read(url) == "{\n  \"hotkey\" : \"cmd+k\"\n}\n")
}

@Test func editionFollowsTheBundleIdentifier() {
    #expect(Edition(bundleIdentifier: "app.wicket.Wicket") == .release)
    #expect(Edition(bundleIdentifier: "app.wicket.Wicket.dev") == .dev)
    #expect(Edition(bundleIdentifier: nil) == .release)
    // Wicket Dev never shares the released app's hotkey or folders.
    #expect(Edition.dev.defaultHotkey != Edition.release.defaultHotkey)
    #expect(Edition.dev.configFolder != Edition.release.configFolder)
    #expect(Edition.dev.supportDirectory != Edition.release.supportDirectory)
    #expect(Edition.release.defaultHotkey.description == "option+space")
}
