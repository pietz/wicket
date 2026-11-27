import Foundation
import Testing

@testable import WicketApp

extension Configuration {
  func save(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

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
  /// A model with no built-in providers that keeps its settings and usage in `folder`, holding every
  /// permission without asking macOS.
  static func testing(in folder: URL, bundled: URL? = ExtensionHost.bundledFolder) -> LauncherModel {
    let model = LauncherModel(
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder, bundled: bundled)
    model.extensions.permissions = Permissions(status: { _ in .granted }, request: { _ in })
    return model
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
  var effectSucceeds = true
  /// Each drawing of what the screens show, once the panel drew it.
  var onDraw: () -> Void = {}
  /// Measures an arriving page instead of the panel.
  var onPrepare: ((Page, String) async -> PageMeasurement)?
  /// Every change drawn, in order.
  var changes: [PaletteChange] = []
  private(set) var presentation = PalettePresentation()
  init(wrapping next: (any PaletteSurface)? = nil) { self.next = next }
  func present(_ change: PaletteChange, _ presentation: PalettePresentation) {
    next?.present(change, presentation)
    self.presentation = presentation
    changes.append(change)
    if change != .selection { onDraw() }
  }
  func prepare(_ page: Page, turn: String) async -> PageMeasurement {
    if let onPrepare { return await onPrepare(page, turn) }
    return await next?.prepare(page, turn: turn) ?? .unmeasured
  }
  /// Up unless a test says otherwise; hiding and showing it change it.
  var shown = true
  var isShown: Bool { next?.isShown ?? shown }
  /// How often the panel was shown.
  var shows = 0
  /// Shows the wrapped panel in place of `show`, such as without ordering it front.
  var showing: ((@escaping () -> Void) -> Void)?
  func show(arriving: @escaping () -> Void) {
    shown = true
    shows += 1
    if let showing {
      showing(arriving)
    } else if let next {
      next.show(arriving: arriving)
    } else {
      arriving()
    }
  }
  @discardableResult func perform(_ effect: PaletteEffect) -> Bool {
    if effect == .hide { shown = false }
    effects.append(effect)
    onEffect(effect)
    return next?.perform(effect) ?? effectSucceeds
  }
  func count(_ effect: PaletteEffect) -> Int { effects.filter { $0 == effect }.count }
}

extension AnswerRenderer {
  /// Shows a page and returns once it is rendered and measured.
  func render(_ page: Page, turn: String) async {
    update(page, turn: turn, streaming: false)
    await settled()
  }
}

/// Starts a loopback HTTP fixture whose first stdout line is its assigned port.
func serveHTTPFixture(in folder: URL, source: String) async throws -> (Process, String) {
  let server = Process()
  server.executableURL = URL(filePath: "/usr/bin/python3")
  server.currentDirectoryURL = folder
  server.arguments = ["-u", "-c", source]
  let output = Pipe()
  server.standardOutput = output
  try server.run()
  let portLine = await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: output.fileHandleForReading.availableData)
    }
  }
  let port = String(decoding: portLine, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard UInt16(port) != nil else {
    if server.isRunning { server.terminate() }
    throw ExtensionFailure("HTTP fixture did not report a port")
  }
  return (server, "http://127.0.0.1:\(port)")
}
