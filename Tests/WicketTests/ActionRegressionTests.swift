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
/// Open and reveal targets are checked only when chosen: a view with a vanished or unsafe file still
/// shows every row, and choosing that one says why and opens nothing.
@MainActor @Test func unsafeOrMissingTargetsDecodeButRefuseWhenChosen() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let document = root.appending(path: "notes.txt")
  try Data("hi".utf8).write(to: document)
  let missing = root.appending(path: "gone.txt")
  var unsafe: [URL] = []
  for name in ["launch.command", "setup.pkg", "executable", "script.py"] {
    let path = root.appending(path: name)
    try Data("echo hi".utf8).write(to: path)
    if name == "executable" {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    unsafe.append(path)
  }
  let targets = [document, missing] + unsafe
  let items = targets.enumerated().map { index, url in
    [
      "id": "\(index)", "title": url.lastPathComponent,
      "actions": [["type": "open", "url": url.absoluteString]],
    ]
  }
  let view = try JSONDecoder().decode(
    ProviderView.self, from: JSONSerialization.data(withJSONObject: ["items": items]))
  #expect(view.items.map(\.actions) == targets.map { [.open($0)] })

  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  // An allowed target is left to the panel to open.
  #expect(!model.activate(.open(document)) && model.actionProblem == nil)
  #expect(!model.activate(.reveal(unsafe[0])) && model.actionProblem == nil)
  for (action, problem) in [
    (RowAction.open(missing), "no longer exists"), (.reveal(missing), "no longer exists"),
    (.reveal(URL(string: "https://example.com")!), "needs a file"),
    (.open(URL(string: "javascript:alert(1)")!), "opens only"),
  ] + unsafe.map({ (RowAction.open($0), "does not open") }) {
    model.actionProblem = nil
    #expect(model.activate(action), "\(action)")
    #expect(model.actionProblem?.contains(problem) == true, "\(action)")
  }
}

@Test func pasteHasNoNewlines() throws {
  #expect(
    try JSONDecoder().decode(RowAction.self, from: Data(#"{"type":"paste","text":"a\r\nb\nc\u2028d"}"#.utf8))
      == .paste("abcd"))
}
