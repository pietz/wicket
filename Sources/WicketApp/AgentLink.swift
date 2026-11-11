import Foundation

/// A tool or permission question the agent raised, for the native confirmation card.
struct AgentPermission: Identifiable, Equatable, Sendable {
  enum Kind: String, Sendable { case edit, read, execute, delete, other }
  /// The CLI's request ID, kept as sent so the reply can echo it.
  let id: JSONValue
  var title: String
  var kind: Kind
  var paths: [String] = []
  var command: String?
  /// What the CLI sent, for Show details.
  var raw: JSONValue = .null
  var detail: String {
    if !paths.isEmpty { return paths.joined(separator: "\n") }
    if let command { return command }
    if raw != .null, let data = try? JSONEncoder().encode(raw) {
      return String(decoding: data, as: UTF8.self)
    }
    return "No location supplied by the agent."
  }
}

/// What AgentSession needs from a CLI, whichever CLI it is.
enum AgentEvent: Equatable, Sendable {
  /// The CLI's own ID of the conversation, to resume it later.
  case session(String)
  /// Answer text. A new `message` ID starts a new message of the answer.
  case text(String, message: String)
  /// A tool started or moved on; the title says what it does.
  case tool(String)
  case permission(AgentPermission)
  /// The turn ended, or was cancelled.
  case finished(cancelled: Bool)
  case failed(String)
}

/// One running CLI. Everything it says arrives as events; a turn ends with `finished` or `failed`.
@MainActor
protocol AgentConnection: AnyObject {
  var onEvent: (AgentEvent) -> Void { get set }
  func prompt(_ text: String, settings: AgentConfiguration)
  func decide(_ id: JSONValue, allow: Bool)
  func cancel()
  /// Ends the process, with the reason it is let go for when the run's log has no other ending.
  func stop(_ reason: String) async
}
extension AgentConnection {
  func stop() async { await stop("stopped") }
}

/// What a translator answers with: events for the session and lines for the CLI.
struct Step {
  var events: [AgentEvent] = []
  var send: [JSONValue] = []
}

/// How to ask a CLI for its models without a model call.
struct Listing: Sendable {
  let arguments: [String]
  let send: [JSONValue]
  /// The models, if this message is the answer.
  let models: @Sendable (JSONValue) -> [AgentModel]?
}

/// One CLI's protocol, as a state machine with no process, timer or UI: each message in gives the
/// events and reply lines out, so recorded traffic can test it.
protocol Translator {
  static var name: String { get }
  /// The CLI's arguments for these settings. Every question starts a new process. `instructions`
  /// are Wicket's, which only a new conversation takes: a resumed one keeps them.
  static func arguments(for settings: AgentConfiguration, resume: String?, instructions: String) -> [String]
  static var listing: Listing { get }
  /// Lines to write when the process starts.
  mutating func start() -> Step
  mutating func prompt(_ text: String, settings: AgentConfiguration) -> Step
  mutating func receive(_ message: JSONValue) -> Step
  mutating func decide(_ id: JSONValue, allow: Bool) -> Step
  mutating func cancel() -> Step
}

/// Joins a translator to its process.
@MainActor
final class AgentLink<T: Translator>: AgentConnection {
  var onEvent: (AgentEvent) -> Void = { _ in }
  private var translator: T
  private let lines: JSONLines
  private let log: AgentLog.Run?
  private var ended = false

  init(_ translator: T, lines: JSONLines, log: AgentLog.Run? = nil) {
    self.translator = translator
    self.lines = lines
    self.log = log
    lines.onMessage = { [weak self] message in
      guard let self else { return }
      apply(self.translator.receive(message))
    }
    lines.onClose = { [weak self] reason in self?.emit(.failed("\(T.name) \(reason)")) }
    apply(self.translator.start())
  }
  func prompt(_ text: String, settings: AgentConfiguration) {
    apply(translator.prompt(text, settings: settings))
  }
  func decide(_ id: JSONValue, allow: Bool) { apply(translator.decide(id, allow: allow)) }
  func cancel() {
    log?.note("CANCEL", "requested")
    apply(translator.cancel())
  }
  func stop(_ reason: String) async {
    await lines.stop()
    end(reason)
    log?.close()
  }
  private func apply(_ step: Step) {
    for line in step.send { lines.send(line) }
    for event in step.events { emit(event) }
  }
  private func emit(_ event: AgentEvent) {
    switch event {
    case .finished(let cancelled): end(cancelled ? "cancelled" : "finished")
    case .failed(let message): end("failed: \(message)")
    default: break
    }
    onEvent(event)
  }
  /// The first ending is the run's: a stop after a finished turn adds nothing.
  private func end(_ outcome: String) {
    guard !ended else { return }
    ended = true
    log?.note("END", outcome)
  }
}
