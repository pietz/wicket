import Foundation
import Testing

@testable import WicketApp

@Test func permissionKeysOverrideActionsAndRespectComposition() {
  #expect(
    PaletteKeyAction.decide(
      keyCode: 36, characters: "\r", modifiers: .command, hasMarkedText: false, permissionPending: true)
      == .permission(true))
  #expect(
    PaletteKeyAction.decide(
      keyCode: 53, characters: nil, modifiers: [], hasMarkedText: false, permissionPending: true)
      == .permission(false))
  #expect(
    PaletteKeyAction.decide(
      keyCode: 36, characters: nil, modifiers: .command, hasMarkedText: true, permissionPending: true)
      == .passThrough)
}
@Test func unsafeFileOpenActionsAreRejectedAndPasteHasNoNewlines() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["launch.command", "setup.pkg", "executable", "script.py"] {
    let path = root.appending(path: name)
    try Data("echo hi".utf8).write(to: path)
    if name == "executable" {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    let data = try JSONSerialization.data(withJSONObject: ["type": "open", "url": path.absoluteString])
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RowAction.self, from: data) }
  }
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      RowAction.self, from: Data(#"{"type":"open","url":"file:///missing/document.txt"}"#.utf8))
  }
  #expect(
    try JSONDecoder().decode(RowAction.self, from: Data(#"{"type":"paste","text":"a\r\nb\nc\u2028d"}"#.utf8))
      == .paste("abcd"))
}
