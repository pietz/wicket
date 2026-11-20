import Foundation
import Testing

@testable import WicketApp

/// Twelve apps for any input, so the root list is at its full eight rows (with Ask agent and Agent History, 14).
@MainActor private final class ManyApps: Provider {
  let id = "apps"
  func view(for request: ProviderRequest) async -> ProviderView {
    .init(items: (0..<12).map { row("App \($0)") })
  }
}

/// What the panel would draw at each publish: which screen, how many rows and the card's height.
@MainActor private final class Frames {
  struct Frame: Equatable {
    let command: String?
    let rows: Int
    let height: CGFloat
  }
  private(set) var all: [Frame] = []
  init(_ model: LauncherModel) {
    model.navigator.onResultsChange = { [weak model] in
      guard let model else { return }
      self.all.append(
        Frame(
          command: model.navigator.command?.id, rows: model.navigator.results.count,
          height: model.navigator.cardHeight(answer: PaletteLayout.answerMin, cap: PaletteLayout.answerMax)))
    }
  }
}

@MainActor private func launcher(_ script: String?, items: [[String: Any]] = []) async throws -> (
  LauncherModel, URL
) {
  let root = try scratch()
  var fields: [String: Any] = ["keyword": "note"]
  if script == nil { fields["items"] = items }
  let folder = try extensionFolder(root, script: script ?? "", fields: fields)
  if script == nil {
    // Items only: the manifest has no program.
    var manifest =
      try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "wicket.json")))
      as! [String: Any]
    manifest.removeValue(forKey: "command")
    try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "wicket.json"))
  }
  let model = LauncherModel(
    apps: ManyApps(), history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  await model.extensions.reload()
  model.navigator.input = "a"
  await model.navigator.settled()
  #expect(model.navigator.results.count > 8 && model.navigator.sizedRows == 8)
  return (model, root)
}

private let full = PaletteLayout.rowsHeight(8) + PaletteLayout.footer
private let one = PaletteLayout.rowsHeight(1) + PaletteLayout.footer

@MainActor @Test func aSlowCommandKeepsTheRootUntilTheDeadlineThenShowsItsOwnHeight() async throws {
  let (model, root) = try await launcher("cat >/dev/null\nsleep 0.6\necho '{\"items\":[]}'")
  defer { try? FileManager.default.removeItem(at: root) }
  let frames = Frames(model)
  model.navigator.go(Address(id: "test"), submitted: true)
  // The root stays exactly as it was: no rows vanish, the height stays.
  #expect(model.navigator.command == nil && model.navigator.input == "a" && model.navigator.sizedRows == 8)
  #expect(frames.all.allSatisfy { $0 == .init(command: nil, rows: 13, height: full) })
  #expect(await eventually { model.navigator.command != nil })
  // After the deadline the command shows, quietly loading, at its own height in the same publish.
  #expect(model.navigator.command?.busy == true && model.navigator.input.isEmpty)
  #expect(frames.all.last == .init(command: "extension:test", rows: 0, height: one))
  await model.navigator.settled()
  #expect(frames.all.filter { $0.command == "extension:test" }.allSatisfy { $0.height == one })
  await model.finish()
}

@MainActor @Test func aCommandThatAnswersInTimeSwitchesContentAndHeightTogether() async throws {
  let (model, root) = try await launcher(answering("Ready"))
  defer { try? FileManager.default.removeItem(at: root) }
  let frames = Frames(model)
  model.navigator.arrivalDeadline = .seconds(5)  // In time, however busy the test machine is.
  model.navigator.go(Address(id: "test"), submitted: true)
  #expect(model.navigator.command == nil && model.navigator.sizedRows == 8)
  await model.navigator.settled()
  #expect(model.navigator.command?.busy == false && model.navigator.results.map(\.row.title) == ["Ready"])
  // Every publish is either the root as it was or the command with its row: never one without the other.
  #expect(
    frames.all.allSatisfy {
      $0 == .init(command: nil, rows: 13, height: full)
        || $0 == .init(command: "extension:test", rows: 1, height: one)
    })
  #expect(frames.all.last?.command == "extension:test")
  await model.finish()
}

@MainActor @Test func aCommandOfOnlyItemsSwitchesBeforeReturnReturns() async throws {
  let (model, root) = try await launcher(
    nil, items: [["id": "one", "title": "One", "actions": [["type": "copy", "text": "1"]]]])
  defer { try? FileManager.default.removeItem(at: root) }
  let frames = Frames(model)
  model.navigator.go(Address(id: "test"), submitted: true)
  #expect(
    model.navigator.command?.id == "extension:test" && model.navigator.results.map(\.row.title) == ["One"])
  #expect(
    model.navigator.sizedRows == 1 && frames.all == [.init(command: "extension:test", rows: 1, height: one)])
  await model.finish()
}

@MainActor @Test func goingBackShowsTheRootWithItsOwnHeightAtOnce() async throws {
  let (model, root) = try await launcher(nil, items: [["id": "one", "title": "One", "actions": []]])
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.go(Address(id: "test"), submitted: true)
  #expect(model.navigator.sizedRows == 1)
  let frames = Frames(model)
  #expect(model.navigator.escape())
  await model.navigator.settled()
  // The root's rows and height arrive together: no 300 ms hold from the command's single row.
  #expect(model.navigator.command == nil && model.navigator.sizedRows == 8)
  #expect(frames.all.allSatisfy { $0.command == "extension:test" ? $0.height == one : $0.height == full })
  await model.finish()
}

@MainActor @Test func typingOrEscapeWhileACommandIsComingIsHandled() async throws {
  let (model, root) = try await launcher("cat >/dev/null\nsleep 0.6\necho '{\"items\":[]}'")
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(5)
  model.navigator.go(Address(id: "test"), submitted: true)
  // Escape calls the switch off and stays at the root.
  #expect(model.navigator.escape() && model.navigator.command == nil && model.navigator.input == "a")
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.navigator.command == nil)
  // Typing goes to the command being entered, which shows at once.
  model.navigator.go(Address(id: "test"), submitted: true)
  model.navigator.editInput("ab")
  #expect(
    model.navigator.command?.id == "extension:test" && model.navigator.input == "b"
      && model.navigator.sizedRows == 1)
  await model.finish()
}

@MainActor @Test func escapeWhileACommandIsComingStopsItsRequest() async throws {
  let (model, root) = try await launcher(
    """
    cat >/dev/null
    sleep 0.3
    echo '{"close":true}'
    """)
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(5)
  var closed = false
  model.navigator.onClose = { closed = true }
  // A late close never hides the root the user stayed on.
  model.navigator.go(Address(id: "test", input: "close"), submitted: true)
  #expect(model.navigator.escape() && model.navigator.command == nil)
  try await Task.sleep(for: .milliseconds(600))
  #expect(!closed)
  await model.finish()
}

@MainActor @Test func aPageShowsOnlyOnceItsBodyIsMeasured() async throws {
  let page = String(
    decoding: try JSONEncoder().encode(ProviderView(body: "# Hello")), as: UTF8.self)
  let (model, root) = try await launcher("cat >/dev/null\nprintf '%s' '\(page)'")
  defer { try? FileManager.default.removeItem(at: root) }
  model.navigator.arrivalDeadline = .seconds(5)
  var prepared: [String] = []
  var release: CheckedContinuation<Void, Never>?
  model.navigator.preparePage = { page, _ in
    prepared.append(page.source)
    await withCheckedContinuation { release = $0 }
  }
  model.navigator.go(Address(id: "test"), submitted: true)
  #expect(await eventually { release != nil })
  // Measuring: the root is still what shows.
  #expect(prepared == ["# Hello"] && model.navigator.command == nil && model.navigator.body == nil)
  release?.resume()
  #expect(await eventually { model.navigator.body == "# Hello" })
  #expect(model.navigator.command?.busy == false)
  await model.finish()
}
