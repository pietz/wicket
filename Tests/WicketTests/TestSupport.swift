import Foundation
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
    navigator.pick().map { navigator.activate($0.action, from: $0.from) } ?? false
  }
  /// A model with no built-in providers that keeps its settings and usage in `folder`.
  static func testing(in folder: URL, bundled: URL? = ExtensionHost.bundledFolder) -> LauncherModel {
    LauncherModel(
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder, bundled: bundled)
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

/// A turn asked as the user would, from the screen shown, and answered.
@MainActor @discardableResult
func finishTurn(_ model: LauncherModel, _ question: String, _ answer: String) async throws -> FakeAgent {
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.navigator.send(question)
  #expect(await eventually { fake.running })
  fake.text(answer)
  fake.end()
  #expect(await eventually { !model.agent.busy && fake.stopped })
  return fake
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

/// A model and its panel with a fake microphone. The panel routes keys and never shows.
@MainActor func voicedPanel(
  in folder: URL, bundled: URL? = ExtensionHost.bundledFolder, panel: PalettePanel = RoutingPanel(),
  transcriber: @escaping () -> any Transcriber
) -> (LauncherModel, PaletteController) {
  let model = LauncherModel.testing(in: folder, bundled: bundled)
  return (model, PaletteController(model: model, panel: panel, transcriber: transcriber))
}

/// Stands in for the panel the screens show in, or stands before it (`next`), which still draws,
/// measures and performs: records what leaves the screens and lets a test see each drawing and hold each
/// page's measurement.
@MainActor final class RecordingSurface: PaletteSurface {
  let next: (any PaletteSurface)?
  var effects: [PaletteEffect] = []
  var onEffect: (PaletteEffect) -> Void = { _ in }
  /// Each drawing of what the screens show, once the panel drew it.
  var onDraw: () -> Void = {}
  /// Measures an arriving page instead of the panel.
  var onPrepare: ((Page, String) async -> Bool)?
  init(wrapping next: (any PaletteSurface)? = nil) { self.next = next }
  func present(_ change: PaletteChange) {
    next?.present(change)
    if change == .content { onDraw() }
  }
  func prepare(_ page: Page, turn: String) async -> Bool {
    if let onPrepare { return await onPrepare(page, turn) }
    return await next?.prepare(page, turn: turn) ?? true
  }
  var holdsReturn: Bool { next?.holdsReturn ?? false }
  func perform(_ effect: PaletteEffect) {
    effects.append(effect)
    onEffect(effect)
    next?.perform(effect)
  }
  func count(_ effect: PaletteEffect) -> Int { effects.filter { $0 == effect }.count }
}
