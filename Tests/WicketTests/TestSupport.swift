import Foundation
import Synchronization
import Testing

@testable import WicketApp

extension ConfigurationStore {
  /// Tests set configuration the way anything else does: by writing the file.
  func update(_ edit: (inout Configuration) -> Void) {
    var value = configuration
    edit(&value)
    try? value.save(at: url)
    load()
  }
}

extension LauncherModel {
  /// Return as the model sees it, without the panel's effects on the system: the selected row's
  /// action, or the follow-up of a conversation. False for an effect the panel would run.
  @discardableResult func activateReturn() -> Bool {
    pick().map { activate($0.action, from: $0.from) } ?? false
  }
  /// A model with no built-in providers that keeps its settings and usage in `folder`.
  static func testing(
    in folder: URL, bundled: URL? = ExtensionHost.bundledFolder, transcriber: (() -> any Transcriber)? = nil
  ) -> LauncherModel {
    LauncherModel(
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
      bundled: bundled, transcriber: transcriber)
  }
}

/// What a fake hotkey registration returns: any object stands for a registered shortcut.
final class Handle {}

/// The requests a test extension logged, one JSON line each, to `log.jsonl` in its folder.
func requests(in folder: URL) throws -> [ProviderRequest] {
  let log = (try? String(contentsOf: folder.appending(path: "log.jsonl"), encoding: .utf8)) ?? ""
  return try log.split(separator: "\n").map {
    try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8))
  }
}

/// Finishes one question through the real session and a fake agent, whose process ends with the turn.
@MainActor @discardableResult
func finishTurn(_ session: AgentSession, _ question: String, _ answer: String) async throws -> FakeAgent {
  let fake = FakeAgent()
  session.connect = { _, _, _ in fake }
  session.ask(question, settings: .init())
  #expect(await eventually { fake.running })
  fake.text(answer)
  fake.end()
  #expect(await eventually { !session.busy && fake.stopped })
  return fake
}

extension ExtensionRunner {
  /// The last view the program printed, as the host's `view` gives it to patterns and headless.
  func run(_ command: ExtensionCommand, request: ProviderRequest) async throws -> ProviderView {
    let last = Mutex<ProviderView?>(nil)
    try await run(command, request: request) { view, _ in last.withLock { $0 = view } }
    return try #require(last.withLock { $0 })
  }
}
