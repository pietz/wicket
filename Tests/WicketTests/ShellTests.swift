import Foundation
import Testing

@testable import WicketApp
@testable import shell

// The bundled Shell hands a command to the default terminal. Nothing here opens one: the hand-over runs
// with a stand-in for `open`, and the `.command` file is run by /bin/sh without a terminal.

private func request(_ input: String, submitted: Bool = false, action: String = "") -> JSON {
  .object(["input": .string(input), "submitted": .bool(submitted), "action": .string(action)])
}

@Test func onlyAChosenCommandIsHandedToTheTerminal() throws {
  // A temporary folder whose name is not ASCII, as a user's can be.
  let temporary = try scratch().appending(path: "café ü")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
  var opened: [String] = []
  let open = { (path: String) in
    opened.append(path)
    return true
  }
  func answered(_ input: String, submitted: Bool = false, action: String = "") -> String {
    answer(request(input, submitted: submitted, action: action), temporary: temporary.path, open: open)
  }
  // Typing, the root and links describe the command; Return on the row runs it with its input.
  let described = try JSONDecoder().decode(ProviderView.self, from: Data(answered("> git status").utf8))
  let row = try #require(described.items.first)
  #expect(row.title == "git status" && row.subtitle == "Open in Terminal")
  #expect(
    row.actions.map(\.kind) == [
      .run(Address(fields: ["command": "git status"], action: "open-terminal", hidden: true))
    ])
  // Nothing typed is a hint; chosen with nothing typed it still runs nothing.
  #expect(answered(">", submitted: true).contains("Type a command after >") && opened.isEmpty)
  #expect(!answered("echo hi", submitted: true).isEmpty && opened.isEmpty)
  #expect(!answered("echo hi", action: "open-terminal").isEmpty && opened.isEmpty)
  // Chosen: written as the user's own executable file and opened, with nothing to show.
  #expect(answered("echo hi", submitted: true, action: "open-terminal").isEmpty)
  let file = try #require(opened.first)
  #expect(file.hasPrefix(temporary.path + "/wicket-shell-") && file.hasSuffix(".command"))
  let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
  #expect(permissions == 0o700)
  #expect(try String(contentsOfFile: file, encoding: .utf8).contains("-l -c 'echo hi'"))
  // Each hand-over is a new file, and one the terminal could not open is removed; the panel stays.
  #expect(answered("pwd", submitted: true, action: "open-terminal").isEmpty && Set(opened).count == 2)
  let refused = answer(request("ls", submitted: true, action: "open-terminal"), temporary: temporary.path) {
    _ in false
  }
  #expect(refused.contains("Could not open the terminal"))
  #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).count == 2)
}

@Test func theTerminalFileRunsTheCommandInTheFolderThenStaysThere() throws {
  #expect(
    terminalScript("echo 'hi'", folder: "/Users/me/it's", shell: "/bin/zsh")
      == #"""
      #!/bin/sh
      cd '/Users/me/it'\''s' || exit 1
      '/bin/zsh' -l -c 'echo '\''hi'\'''
      exec '/bin/zsh' -l

      """#)
  // Run as the terminal would run it, here without a terminal.
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appending(path: "it's")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let file = try #require(
    writeCommandFile(terminalScript("pwd > out; exit", folder: folder.path, shell: "/bin/sh"), in: root.path))
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [file]
  process.standardInput = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(try String(contentsOf: folder.appending(path: "out"), encoding: .utf8) == folder.path + "\n")
}

@Test func aHandOverSweepsTheTerminalFilesOfEarlierOnes() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in ["wicket-shell-1.command", "wicket-shell-2.command", "other.command"] {
    try Data().write(to: root.appending(path: name))
  }
  for name in ["wicket-shell-1.command", "other.command"] {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: root.appending(path: name).path)
  }
  sweep(root.path)
  // The old one goes; one the terminal may still be opening and anything else stay.
  let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  #expect(left == ["other.command", "wicket-shell-2.command"])
}

/// The built program at the root: one row for what is typed, and nothing written or run.
@MainActor @Test func theRootOffersTheCommandAsOneRow() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let temporary = root.appending(path: "tmp")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  let folder = root.appending(path: "extensions/shell")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var manifest =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: bundledExtensions.appending(path: "shell/wicket.json"))) as! [String: Any]
  manifest["command"] = [
    "/usr/bin/env", "TMPDIR=" + temporary.path, bundledExtensions.appending(path: "shell/main").path,
  ]
  try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.navigator.input = "> touch x"
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["touch x"])
  #expect(model.navigator.results.first?.row.subtitle == "Open in Terminal")
  #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
  await model.finish()
}
