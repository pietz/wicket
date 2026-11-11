import Foundation
import Observation

/// Owns a conversation: one CLI process per question, which ends with the turn, and the session ID
/// that the next question resumes. No window dependency.
@MainActor @Observable
final class AgentSession {
  struct Turn: Identifiable {
    let id: String
    let question: String
    let answer: String
  }
  private(set) var previous: [Turn] = []
  private(set) var continuing = false
  var agentName: String { chosen.agent.title }
  private(set) var active = false
  private(set) var busy = false
  private(set) var turnID = UUID().uuidString
  private(set) var question = ""
  private(set) var answer = ""
  private(set) var status = ""
  private(set) var problem: String?
  private(set) var permissions: [AgentPermission] = []
  var onChange: (() -> Void)?
  let folder: URL
  private(set) var sessionID: String?
  private var connection: (any AgentConnection)?
  private var chosen = AgentConfiguration()
  private var pendingAnswer = ""
  private var messageID: String?
  var streaming: Bool { chosen.streamAnswers }
  private func publishAnswer() {
    guard !pendingAnswer.isEmpty else { return }
    answer += pendingAnswer
    pendingAnswer = ""
  }
  private var heard = false
  private var acceptingUpdates = false
  /// Cancel was pressed for this turn: nothing new is prompted or allowed from then on.
  private var cancelling = false
  private var generation = 0
  private var task: Task<Void, Never>?
  private var permissionExpiry: Task<Void, Never>?
  private var cancelDeadline: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  /// Every connection that was let go and is still stopping, so `shutdown` can wait for it.
  private var teardown: Task<Void, Never>?
  /// The last hide or turn completion. Nil until the first one.
  private var lastActivity: Date?
  var cancelGrace: Duration = .seconds(3)
  var retention: TimeInterval = 300
  /// No event at all from a CLI that started, then no end to the turn.
  var startupLimit: Duration = .seconds(30)
  var turnLimit: Duration = .seconds(600)
  /// Everything stays for `retention` after the last hide or completion, whichever is later.
  private var retainedUntil: Date? { lastActivity?.addingTimeInterval(retention) }
  /// Starts the CLI for one question with these settings in the folder, resuming the session ID if there is one.
  var connect: (AgentConfiguration, URL, String?) async throws -> any AgentConnection = {
    try await AgentCLI.connect($0, folder: $1, resume: $2)
  }

  init(folder: URL) { self.folder = folder }
  /// After the retention window, pending permissions are declined, even while busy. Unless a turn
  /// is still running, the conversation ends too. Returns true then: the caller drops its draft.
  @discardableResult func reopen(now: Date = Date()) -> Bool {
    permissionExpiry?.cancel()
    guard let retainedUntil, now > retainedUntil else { return false }
    declineAll()
    guard !busy else { return false }
    if active { reset() }
    lastActivity = nil
    return true
  }
  func hidden(now: Date = Date()) {
    lastActivity = max(lastActivity ?? now, now)
    if active { continuing = true }
    permissionExpiry?.cancel()
    guard !permissions.isEmpty, let retainedUntil else { return }
    let delay = max(0, retainedUntil.timeIntervalSince(now))
    permissionExpiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      declineAll()
    }
  }
  func ask(_ input: String, settings: AgentConfiguration) {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, !input.isEmpty else { return }
    if chosen.agent != settings.agent { reset() }
    if active {
      previous.append(Turn(id: turnID, question: question, answer: answer))
      previous = Array(previous.suffix(10))
    }
    continuing = false
    permissionExpiry?.cancel()
    cancelDeadline?.cancel()
    turnID = UUID().uuidString
    heard = false
    problem = nil
    chosen = settings
    active = true
    busy = true
    acceptingUpdates = false
    cancelling = false
    question = input
    answer = ""
    pendingAnswer = ""
    messageID = nil
    status = "Connecting to \(settings.agent.title)…"
    permissions = []
    lastActivity = Date()
    generation += 1
    let version = generation
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connection = try await connect(chosen, folder, sessionID)
        guard generation == version, !cancelling else {
          await connection.stop()
          guard generation == version, busy else { return }
          status = "Cancelled"
          finishTurn()
          return
        }
        self.connection = connection
        connection.onEvent = { [weak self] event in
          guard let self, generation == version else { return }
          receive(event)
        }
        acceptingUpdates = true
        status = "Thinking…"
        var text =
          "Wicket executable (supports --query and --extension for headless tests): \(ProcessInfo.processInfo.environment["WICKET_EXECUTABLE"] ?? Bundle.main.executableURL?.path ?? "Wicket"). Wicket working folder: \(folder.path). Extension contract: \(folder.appending(path: "extension-contract.md").path). Write extensions into \(folder.appending(path: "extensions").path); Wicket discovers them and they are on unless the owner switches them off. Read the contract before authoring.\n\nUser: \(input)"
        if let instructions = try? String(
          contentsOf: folder.appending(path: "agent-instructions.md"), encoding: .utf8)
        {
          text = "Wicket display instructions:\n\(instructions)\n\n\(text)"
        }
        arm(startupLimit)
        connection.prompt(text, settings: chosen)
      } catch {
        guard generation == version else { return }
        if cancelling {
          status = "Cancelled"
          finishTurn()
        } else {
          fail(error.localizedDescription)
        }
      }
    }
    onChange?()
  }
  /// A turn that never starts or never ends fails instead of waiting forever.
  private func arm(_ limit: Duration) {
    deadline?.cancel()
    let version = generation
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: limit) } catch { return }
      guard let self, generation == version, busy else { return }
      fail("\(chosen.agent.product) took too long. Check that it works in Terminal, then try again.")
    }
  }
  /// The turn failed: show why and end the turn.
  private func fail(_ message: String) {
    status = message
    problem = message
    finishTurn()
  }

  private func receive(_ event: AgentEvent) {
    if !heard {
      heard = true
      arm(turnLimit)
    }
    switch event {
    case .session(let id):
      sessionID = id
    case .text(var text, let id):
      guard acceptingUpdates, !text.isEmpty else { return }
      let boundary = id != messageID
      if boundary {
        publishAnswer()
        messageID = id
        // Separate messages are separate paragraphs, whichever way they arrive.
        if !answer.isEmpty { text = "\n\n" + text }
      }
      if answer.utf8.count + pendingAnswer.utf8.count + text.utf8.count <= 1_048_576 {
        if streaming {
          answer += text
        } else {
          pendingAnswer += text
          status = "Working…"
          if boundary { onChange?() }
          return
        }
      } else {
        problem = "Answer reached the 1 MB limit"
        cancel()
      }
    case .tool(let title):
      guard acceptingUpdates else { return }
      publishAnswer()
      messageID = nil
      status = title
    case .permission(let permission):
      guard acceptingUpdates, !cancelling else {
        connection?.decide(permission.id, allow: false)
        return
      }
      permissions.append(permission)
    case .finished(let cancelled):
      guard busy else { return }
      status = cancelled ? "Cancelled" : "Ready for a follow-up"
      finishTurn()
      return
    case .failed(let message):
      // A process that ended after its turn is not an error.
      guard busy else { return }
      fail(message)
      return
    }
    onChange?()
  }
  func decide(_ allow: Bool) {
    guard let permission = permissions.first else { return }
    connection?.decide(permission.id, allow: allow)
    permissions.removeFirst()
    onChange?()
  }
  func cancel() {
    guard busy, !cancelling else { return }
    cancelling = true
    declineAll()
    status = "Cancelling…"
    task?.cancel()
    connection?.cancel()
    let version = generation
    let grace = cancelGrace
    cancelDeadline = Task { [weak self] in
      do { try await Task.sleep(for: grace) } catch { return }
      guard let self, generation == version, busy else { return }
      generation += 1
      let cancelledVersion = generation
      let old = connection
      connection = nil
      acceptingUpdates = false
      await release(old).value
      guard generation == cancelledVersion else { return }
      status = "Cancelled"
      finishTurn()
    }
    onChange?()
  }
  /// The turn is over, however it ended: its process ends with it.
  private func finishTurn() {
    publishAnswer()
    declineAll()
    busy = false
    acceptingUpdates = false
    cancelling = false
    lastActivity = Date()
    cancelDeadline?.cancel()
    deadline?.cancel()
    release(connection)
    connection = nil
    onChange?()
  }
  /// Every pending permission is refused, so the CLI is never left waiting on one.
  private func declineAll() {
    while !permissions.isEmpty { decide(false) }
  }
  /// Stops a connection that is let go, in the order they were let go. `shutdown` waits for it.
  @discardableResult
  private func release(_ old: (any AgentConnection)?) -> Task<Void, Never> {
    let before = teardown
    let stopping = Task {
      await before?.value
      await old?.stop()
    }
    teardown = stopping
    return stopping
  }
  func reset() {
    generation += 1
    task?.cancel()
    cancelDeadline?.cancel()
    permissionExpiry?.cancel()
    deadline?.cancel()
    declineAll()
    release(connection)
    connection = nil
    active = false
    previous = []
    continuing = false
    busy = false
    sessionID = nil
    answer = ""
    pendingAnswer = ""
    messageID = nil
    question = ""
    status = ""
    problem = nil
    acceptingUpdates = false
    cancelling = false
    onChange?()
  }
  /// Returns once every process this session started has stopped, even one that was still starting.
  func shutdown() async {
    let starting = task
    reset()
    await starting?.value
    await teardown?.value
  }
}
