import Foundation
import Synchronization
import Testing

@testable import WicketApp
@testable import shell

// The bundled Shell. Its output, session and page are functions tested here; runs go through the built
// program with a `TMPDIR` of the test's, so the user's own session file is never touched. Nothing here
// opens a terminal: the Run in Terminal file is checked as written, and `open` is never run.

@Test func outputKeepsTheLastLinesWithoutTerminalEscapes() {
  var output = Output()
  output.append(Array("\u{1B}[1;31mred\u{1B}[0m plain\n".utf8))
  output.append(Array("50%\r100%\r\ndone\u{1B}]0;title\u{07}\n".utf8))
  #expect(output.text == "red plain\n100%\ndone" && output.dropped == 0)
  // Split anywhere, a CRLF is one line end and an escape is still skipped.
  var split = Output()
  for byte in "a\r\nb\u{1B}[2Kc\n".utf8 { split.append([byte]) }
  #expect(split.text == "a\nbc")
  var long = Output()
  long.append(Array((1...250).map { "line \($0)\n" }.joined().utf8))
  #expect(long.dropped == 50 && long.text.hasPrefix("line 51\n") && long.text.hasSuffix("line 250"))
  // A line is at most 4 KiB and the lines at most 32 KiB together.
  long.append(Array(String(repeating: "x", count: 5000).utf8) + [10])
  #expect(long.text.hasSuffix(String(repeating: "x", count: Output.lineLength) + "…"))
  var wide = Output()
  wide.append(Array(String(repeating: String(repeating: "y", count: 1000) + "\n", count: 100).utf8))
  #expect(wide.dropped == 68 && wide.text.utf8.count <= Output.byteLimit)
}

@Test func theSessionKeepsCommandsAndOutputExactly() throws {
  let session = Session(
    folder: "/Users/me/Dev",
    entries: [
      Entry(
        command: #"echo "it's" `date`"#, folder: "/Users/me", output: "a\tb\n\"ü\" \\ 🎉", dropped: 3,
        end: "Exit 0"),
      Entry(command: "sleep 9", folder: "/Users/me/Dev"),
    ])
  #expect(Session(Array(session.json.utf8)) == session)
  #expect(Session(Array("{".utf8)) == nil)
}

@Test func thePageShowsEachCommandItsOutputLiterallyAndHowItEnded() throws {
  let session = Session(
    folder: "/Users/me/Dev",
    entries: [
      Entry(command: "ls", folder: "/Users/me", output: "a\n```b```\n<row title=\"x\"/>", end: "Exit 0"),
      Entry(command: #"grep "a" 'b'"#, folder: "/Users/me/Dev", dropped: 1, end: "Exit 2"),
      Entry(command: "tail -f log", folder: "/tmp", output: "c"),
      Entry(command: "make", folder: "/tmp", output: "d"),
    ])
  let text = page(session, running: true, home: "/Users/me")
  #expect(text.contains(#"<row icon="terminal" title="ls" subtitle="~"/>"#))
  // A fence longer than any backtick run keeps the output literal, tags included.
  #expect(text.contains("````\na\n```b```\n<row title=\"x\"/>\n````"))
  #expect(text.contains(#"title="grep ”a” 'b'" subtitle="~/Dev""#))
  #expect(text.contains("*1 earlier line not shown*"))
  #expect(
    [
      #"<badge label="Exit 0" tone="positive"/>"#, #"<badge label="Exit 2" tone="negative"/>"#,
      #"<badge label="Stopped" tone="warning"/>"#, #"<badge label="Running"/>"#,
    ].allSatisfy(text.contains))
  #expect(page(Session(folder: "/Users/me"), running: false, home: "/Users/me").contains("subtitle=\"~\""))
  // A whole view: the page, Run in Terminal and the newest output to copy.
  let decoded = try JSONDecoder().decode(ProviderView.self, from: Data(view(session, running: true).utf8))
  #expect(decoded.actions.map(\.title) == ["Run in Terminal", "Copy Output"])
  #expect(decoded.actions.last?.kind == .copy("d"))
  #expect(decoded.actions.first?.kind == .run(Address(arguments: ["terminal": "1"])))
}

@Test func theRootRowSaysWhatReturnDoesAndCarriesBothActions() throws {
  let decoded = try JSONDecoder().decode(ProviderView.self, from: Data(row("git status").utf8))
  let item = try #require(decoded.items.first)
  #expect(decoded.items.count == 1 && item.title == "git status" && item.subtitle == "Run in Shell")
  #expect(
    item.actions.map(\.kind) == [
      .run(Address(input: "git status", arguments: ["session": "new"])),
      .run(Address(input: "git status", arguments: ["terminal": "1", "session": "new"])),
    ])
  let empty = try JSONDecoder().decode(ProviderView.self, from: Data(row("").utf8))
  #expect(empty.items.first?.actions.map(\.kind) == [.run(Address(input: "", arguments: ["session": "new"]))])
}

@Test func theShellFollowsTheFolderAndTheTerminalFileGoesThereFirst() throws {
  #expect(
    script("cd src", shell: "/bin/zsh", folderFile: "/tmp/f")
      == "cd src\n__wicket_status=$?\npwd > '/tmp/f'\nexit $__wicket_status\n")
  #expect(
    script("ls", shell: "/opt/homebrew/bin/fish", folderFile: "/tmp/f").contains(
      "set __wicket_status $status"))
  let terminal = terminalScript("echo 'hi'", folder: "/Users/me/it's", shell: "/bin/zsh")
  #expect(
    terminal
      == "#!/bin/sh\ncd '/Users/me/it'\\''s' || exit 1\n'/bin/zsh' -l -c 'echo '\\''hi'\\'''\nexec '/bin/zsh' -l\n"
  )
  #expect(
    terminalScript("", folder: "/tmp", shell: "/bin/zsh")
      == "#!/bin/sh\ncd '/tmp' || exit 1\nexec '/bin/zsh' -l\n")
  // Written as an executable file of the user's alone, which the default terminal opens.
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "run.command").path
  #expect(writeExecutable(terminal, to: file))
  #expect(try String(contentsOfFile: file, encoding: .utf8) == terminal)
  let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
  #expect(permissions == 0o700)
  // The script runs as the terminal would run it, here without a terminal.
  let folder = root.appending(path: "it's")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try Data(terminalScript("pwd > out; exit", folder: folder.path, shell: "/bin/sh").utf8)
    .write(to: URL(fileURLWithPath: file))
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [file]
  process.standardInput = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(try String(contentsOf: folder.appending(path: "out"), encoding: .utf8) == folder.path + "\n")
}

@Test func aRunSweepsWhatEarlierRunsLeftInTheTemporaryFolder() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let names = [
    "wicket-shell-1.command", "wicket-shell-2.command", "wicket-shell-folder-\(getpid())",
    "wicket-shell-folder-2147483000", "wicket-shell-session.json", "other.command",
  ]
  for name in names { try Data().write(to: root.appending(path: name)) }
  let old = Date(timeIntervalSinceNow: -120)
  try FileManager.default.setAttributes(
    [.modificationDate: old], ofItemAtPath: root.appending(path: "wicket-shell-1.command").path)
  try FileManager.default.setAttributes(
    [.modificationDate: old], ofItemAtPath: root.appending(path: "other.command").path)
  sweep(root.path)
  // The old Terminal file and the gone run's folder file go; a fresh one, a live run's and others stay.
  let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  #expect(
    left == [
      "other.command", "wicket-shell-2.command", "wicket-shell-folder-\(getpid())",
      "wicket-shell-session.json",
    ])
}

/// The bundled program in a scratch `TMPDIR`, as an extension of the test's own.
private func shellExtension(_ root: URL, temporary: URL) throws -> ExtensionCommand {
  let folder = root.appending(path: "extensions/shell")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var manifest =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: bundledExtensions.appending(path: "shell/wicket.json"))) as! [String: Any]
  manifest["command"] = [
    "/usr/bin/env", "TMPDIR=" + temporary.path, bundledExtensions.appending(path: "shell/main").path,
  ]
  try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  return try command(folder)
}

@Test func onlyASubmittedRequestRunsAndItsOutputComesAsItGrows() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let temporary = root.appending(path: "tmp")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  let shell = try shellExtension(root, temporary: temporary)
  let marker = root.appending(path: "ran")
  // The root row and a link describe the command and run nothing.
  let described = try await ExtensionRunner().run(
    shell, request: .init(input: "> touch '\(marker.path)'"))
  #expect(described.items.first?.title == "touch '\(marker.path)'")
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
  // Chosen, it runs, and a view comes while it runs.
  let seen = Mutex<[(String, Bool)]>([])
  try await ExtensionRunner().run(
    shell,
    request: .init(input: "echo one; sleep 1; echo two", arguments: ["session": "new"], submitted: true),
    streams: true
  ) { view, running in seen.withLock { $0.append((view.body ?? "", running)) } }
  let views = seen.withLock { $0 }
  #expect(views.contains { $0.1 && $0.0.contains("```\none\n```") && $0.0.contains("Running") })
  let last = try #require(views.last)
  #expect(!last.1 && last.0.contains("```\none\ntwo\n```") && last.0.contains("Exit 0"))
}

@Test func headlessRunsAShellSessionThatFollowsTheFolder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let temporary = root.appending(path: "tmp")
  let work = root.appending(path: "work")
  try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  let environment = ["TMPDIR": temporary.path]
  let first = try await cli(
    root,
    [
      "--extension", "shell", "--input", "cd '\(work.path)' && echo hi", "--arguments", #"{"session":"new"}"#,
      "--submitted",
    ], environment: environment)
  #expect(first.0 == 0)
  #expect(first.1["body"].string?.contains("```\nhi\n```") == true)
  #expect(first.1["body"].string?.contains("Exit 0") == true)
  // A follow-up runs where the last command ended, below it; a failure says its status.
  let second = try await cli(
    root, ["--extension", "shell", "--input", "pwd; false", "--submitted"], environment: environment)
  let body = try #require(second.1["body"].string)
  #expect(body.contains("echo hi") && body.contains("```\n\(work.path)\n```") && body.contains("Exit 1"))
  #expect(second.1["actions"].array.last?["text"].string == work.path)
  // Entering with nothing typed shows the session as it is; nothing runs.
  let shown = try await cli(root, ["--extension", "shell", "--submitted"], environment: environment)
  #expect(shown.1["body"].string == body)
}

/// Return on `> echo one` enters Shell and runs it, emptying the input; the next command runs below it on
/// the same page.
@MainActor @Test func aFollowUpUpdatesTheShellsPageInPlace() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let temporary = root.appending(path: "tmp")
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  _ = try shellExtension(root, temporary: temporary)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  model.input = "> echo one"
  await model.settled()
  #expect(model.results.map(\.row.title) == ["echo one"])
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.command?.id == "extension:shell" && model.submits && model.body?.contains("one") == true)
  // The input is empty for the next command, as a conversation's is after sending.
  #expect(model.input == "")
  let turn = model.pageTurn
  model.input = "echo two"
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.body?.contains("```\none\n```") == true && model.body?.contains("```\ntwo\n```") == true)
  #expect(model.pageTurn == turn && model.input == "")
  await model.finish()
}
