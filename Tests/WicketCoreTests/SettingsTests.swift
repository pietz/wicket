import Carbon.HIToolbox
import Foundation
import Testing

@testable import WicketCore

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
    #expect(throws: DecodingError.self) { try decode(#"{"hotkey": "option+spacebar"}"#) }
    #expect(throws: DecodingError.self) { try decode(#"{"hotkey": 1}"#) }
    #expect(throws: DecodingError.self) { try decode("not json") }
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

/// A bad width is reported, not fixed: the file keeps it until the width itself is changed.
@Test func updateKeepsIgnoredWidth() throws {
    let url = temporarySettingsURL()
    try write(#"{"hotkey": "cmd+k", "paletteWidth": "wide"}"#, to: url)
    try Settings.update(at: url) { $0.hotkey = .default }
    #expect(try read(url).contains(#""paletteWidth" : "wide""#))
    try Settings.update(at: url) { $0.paletteWidth = 720 }
    #expect(try Settings.load(from: url).paletteWidth == 720)
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
    for json in ["not json", #"{"hotkey": "option+spacebar", "x": 1}"#, "[1]"] {
        try write(json, to: url)
        #expect(throws: Settings.InvalidFile.self) { try Settings.update(at: url) { $0.hotkey = .default } }
        #expect(throws: Settings.InvalidFile.self) { try Settings.load(from: url) }
        #expect(try read(url) == json)
    }
}

@Test func invalidFileExplainsWhy() throws {
    let url = temporarySettingsURL()
    try write(#"{"hotkey": "option+spacebar"}"#, to: url)
    #expect(
        throws: Settings.InvalidFile(
            description: #"hotkey: "option+spacebar": unknown key or modifier "spacebar""#)
    ) {
        try Settings.load(from: url)
    }
}
