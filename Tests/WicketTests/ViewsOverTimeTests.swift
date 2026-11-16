import Darwin
import Foundation
import Synchronization
import Testing

@testable import WicketApp

// Views over time: an open command's program may print one view per line, each replacing the last.

/// A program that writes its pid, prints `views` one line each with `pause` seconds between them, then
/// waits `rest` seconds before it exits.
private func streaming(_ views: [String], pause: String = "0.3", rest: String? = nil) -> String {
  "cat >/dev/null\necho $$ > pid\n"
    + views.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\nsleep \(pause)\n")
    + (rest.map { "\nsleep " + $0 } ?? "")
}
private func body(_ text: String) -> String {
  String(decoding: try! JSONEncoder().encode(ProviderView(body: text)), as: UTF8.self)
}
private func list(_ title: String) -> String {
  String(
    decoding: try! JSONEncoder().encode(ProviderView(items: [Row(id: "one", title: title, actions: [])])),
    as: UTF8.self)
}
private func alive(_ folder: URL) -> Bool {
  guard let text = try? String(contentsOf: folder.appending(path: "pid"), encoding: .utf8),
    let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  else { return false }
  return kill(pid, 0) == 0
}

@Test func eachLineIsAViewAndOnlyTheFirstHasADeadline() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(
    root, script: streaming([body("one"), body("two"), body("three")], pause: "1.2"))
  var runner = ExtensionRunner()
  runner.deadline = .seconds(1)
  let seen = Mutex<[(String, Bool)]>([])
  try await runner.run(command(ext), request: .init(input: "")) { view, running in
    seen.withLock { $0.append((view.body ?? "", running)) }
  }
  // Each came while the program ran, in order, the newest when the reader fell behind, and after the
  // deadline for the first; the last with its exit.
  let views = seen.withLock { $0 }
  #expect(views.count >= 2 && views.last! == ("three", false) && views.dropLast().allSatisfy(\.1))
  #expect(views.map(\.0) == ["one", "two", "three"].filter { name in views.contains { $0.0 == name } })
  // A first view later than the deadline is a timeout, as a program that prints nothing is.
  try Data(("cat >/dev/null\nsleep 2\nprintf '%s\\n' '" + body("late") + "'").utf8)
    .write(to: ext.appending(path: "main.sh"))
  await #expect(throws: ExtensionFailure.self) {
    try await runner.run(command(ext), request: .init(input: ""))
  }
}

/// A lone view, pretty-printed JSON and Markdown are one view each, with the exit, as before views over
/// time; output after line views must be a view too.
@Test func aLoneViewArrivesWithTheExit() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let pretty = String(
    decoding: try JSONEncoder.pretty.encode(
      ProviderView(items: [Row(id: "a", title: "A", actions: [.copy("A")])])), as: UTF8.self)
  for (script, expected) in [
    ("cat >/dev/null\nprintf '%s\\n' '\(body("lone"))'", ProviderView(body: "lone")),
    (
      "cat >/dev/null\ncat <<'EOF'\n\(pretty)\nEOF",
      ProviderView(items: [Row(id: "a", title: "A", actions: [.copy("A")])])
    ),
    (
      "cat >/dev/null\nprintf '## Done\\n{\"body\":\"x\"}\\n'",
      ProviderView(body: "## Done\n{\"body\":\"x\"}")
    ),
  ] {
    let ext = try extensionFolder(root, script: script)
    let seen = Mutex<[(ProviderView, Bool)]>([])
    try await ExtensionRunner().run(command(ext), request: .init(input: "")) { view, running in
      seen.withLock { $0.append((view, running)) }
    }
    #expect(seen.withLock { $0.map(\.0) } == [expected])
    #expect(seen.withLock { $0.map(\.1) } == [false])
  }
  let ext = try extensionFolder(root, script: streaming([body("one")]) + "echo not a view")
  let error = await #expect(throws: ExtensionFailure.self) {
    try await ExtensionRunner().run(command(ext), request: .init(input: ""))
  }
  #expect(error?.message.contains("Invalid extension view") == true)
}

@MainActor @Test func anOpenCommandShowsEachViewOnOnePageUntilEscapeStopsIt() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, script: streaming([body("one"), body("two")], pause: "1", rest: "30"))
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  model.go(Address(id: "test"), chosen: true)
  #expect(await eventually(within: .seconds(5)) { model.body == "one" })
  let turn = model.pageTurn
  #expect(model.command?.live == true && model.command?.busy == true)
  // The next view replaces it on the same page, which the renderer updates in place.
  #expect(await eventually(within: .seconds(5)) { model.body == "two" })
  #expect(model.pageTurn == turn && model.command?.live == true)
  // Escape stops the program and stays on its last view; the next Escape goes back.
  #expect(model.escape())
  #expect(model.command?.id == "extension:test" && model.body == "two" && model.command?.live == false)
  #expect(await eventually(within: .seconds(5)) { !alive(ext) })
  #expect(model.escape() && model.command?.id == nil)
  await model.finish()
}

@MainActor @Test func leavingOrHidingStopsARunningView() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let ext = try extensionFolder(root, script: streaming([list("one")], rest: "30"))
  let model = LauncherModel.testing(in: root)
  await model.extensions.reload()
  for leave in [{ model.dismiss() }, { model.go(Address(extensionName: "")) }] {
    model.go(Address(id: "test"), chosen: true)
    #expect(await eventually(within: .seconds(5)) { model.results.first?.row.title == "one" && alive(ext) })
    #expect(model.command?.live == true)
    leave()
    #expect(await eventually(within: .seconds(5)) { !alive(ext) })
  }
  await model.finish()
}

/// Patterns, hotkeys and headless show only the last view.
@MainActor @Test func patternsAndHeadlessKeepTheFinalView() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, script: streaming([list("first"), list("final")], pause: "0.2"), fields: ["match": "^stream"])
  try saveProviders([.init("extension:test")], in: root)
  let model = LauncherModel.testing(in: root)
  model.store.start(watching: false)
  await model.extensions.reload()
  model.input = "stream"
  await model.settled()
  #expect(model.results.map(\.row.title) == ["final"])
  await model.finish()
  let (status, output) = try await cli(root, ["--extension", "test"])
  #expect(status == 0 && output["items"].array.map { $0["title"].string } == ["final"])
}

extension JSONEncoder {
  fileprivate static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    return encoder
  }
}
