import Foundation
import Observation

/// Owns a conversation: one CLI process per question, which ends with the turn, and the session ID
/// that the next question resumes. No window dependency.
@MainActor @Observable
final class AgentSession {
  typealias Turn = AgentHistory.Run.Turn
  /// The last ten earlier turns, which Agent History saves with the last one.
  private(set) var previous: [Turn] = []
  private(set) var continuing = false
  var agentName: String { chosen.agent.title }
  private(set) var active = false
  private(set) var busy = false {
    didSet { if busy != oldValue { page = Page(body: answer, runs: false, streaming: busy) } }
  }
  private(set) var turnID = UUID().uuidString
  private(set) var question = ""
  /// The command the question was asked from, whose context went with it; nil for a follow-up.
  private(set) var source: String?
  private(set) var answer = "" { didSet { page = Page(body: answer, runs: false, streaming: busy) } }
  /// The answer as a page, with what it lets the user act on where it stands. Never a run action.
  private(set) var page = Page(body: "", runs: false)
  private(set) var status = ""
  private(set) var problem: String?
  private(set) var permissions: [AgentPermission] = []
  var onChange: (() -> Void)?
  let folder: URL
  private(set) var sessionID: String?
  /// Where each finished turn is saved, as the run `runID`.
  var history: AgentHistory?
  private(set) var runID = UUID().uuidString
  /// The command the first question was asked from, which the run keeps.
  private var runSource: String?
  /// The agent of a run reopened from Agent History, which its follow-ups keep; nil otherwise.
  private(set) var reopened: AgentConfiguration.Agent?
  /// One quiet line under the question: the session could not be resumed, so the answer started afresh.
  private(set) var notice: String?
  /// The CLI was asked to resume a session and has not confirmed it yet.
  private var resuming = false
  /// What the current question sends, context included.
  private var prompt = ""
  private var connection: (any AgentConnection)?
  private var chosen = AgentConfiguration()
  private var pendingAnswer = ""
  /// What the agent said before its last tool call ("Let me check…"): narration, not the answer,
  /// unless nothing follows it.
  private var narration = ""
  private var messageID: String?
  var streaming: Bool { chosen.streamAnswers }
  private func publishAnswer() {
    guard !pendingAnswer.isEmpty else { return }
    answer += pendingAnswer
    pendingAnswer = ""
  }
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
  var retention: TimeInterval = 1200
  /// No event at all from a CLI that started, then no event for this long during the turn: a working
  /// agent is never cut off, a hung one is. While a permission waits for the user, no limit runs.
  var startupLimit: Duration = .seconds(30)
  var turnLimit: Duration = .seconds(600)
  /// Everything stays for `retention` after the last hide or completion, whichever is later.
  private var retainedUntil: Date? { lastActivity?.addingTimeInterval(retention) }
  /// Starts the CLI for one question with these settings in the folder, resuming the session ID if there is one.
  var connect: (AgentConfiguration, URL, String?) async throws -> any AgentConnection

  init(folder: URL, log: AgentLog = .standard()) {
    self.folder = folder
    connect = { try AgentCLI.connect($0, folder: $1, resume: $2, log: log) }
  }
  /// After the retention window, pending permissions are declined, even while busy. Unless a turn
  /// is still running, the conversation ends too. Returns true then: the caller drops its draft.
  @discardableResult func reopen(now: Date = Date()) -> Bool {
    isHidden = false
    permissionExpiry?.cancel()
    guard let retainedUntil, now > retainedUntil else { return false }
    declineAll()
    guard !busy else { return false }
    if active { reset() }
    lastActivity = nil
    return true
  }
  func hidden(now: Date = Date()) {
    isHidden = true
    lastActivity = max(lastActivity ?? now, now)
    if active { continuing = true }
    expirePermissions(now: now)
  }
  /// The panel is hidden: a permission asked now is declined at the same deadline as one pending at the
  /// hide, since no limit runs while it waits.
  private var isHidden = false
  /// Declines the pending permissions once `retention` after the last hide or completion has passed.
  private func expirePermissions(now: Date = Date()) {
    permissionExpiry?.cancel()
    guard !permissions.isEmpty, let retainedUntil else { return }
    let delay = max(0, retainedUntil.timeIntervalSince(now))
    permissionExpiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      declineAll()
    }
  }
  /// An empty conversation with these settings, waiting for its first question. No process starts.
  func open(settings: AgentConfiguration) {
    if active { reset() }
    chosen = settings
    active = true
    onChange?()
  }
  /// Asks `input`, which the conversation shows. A `context` block goes before it to the agent only.
  func ask(_ input: String, context: String? = nil, from source: String? = nil, settings: AgentConfiguration)
  {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, !input.isEmpty else { return }
    if chosen.agent != settings.agent { reset() }
    if active, !question.isEmpty {
      previous.append(Turn(question: question, answer: answer))
      previous = Array(previous.suffix(10))
    }
    continuing = false
    permissionExpiry?.cancel()
    cancelDeadline?.cancel()
    turnID = UUID().uuidString
    problem = nil
    chosen = settings
    active = true
    busy = true
    acceptingUpdates = false
    cancelling = false
    question = input
    self.source = context == nil ? nil : source
    if previous.isEmpty { runSource = self.source }
    notice = nil
    prompt = context.map { "\($0)\n\n\(input)" } ?? input
    answer = ""
    pendingAnswer = ""
    narration = ""
    messageID = nil
    status = "Connecting to \(settings.agent.title)…"
    permissions = []
    lastActivity = Date()
    launch()
    onChange?()
  }
  /// Starts the CLI for the current question, resuming the session if there is one.
  private func launch() {
    generation += 1
    let version = generation
    resuming = sessionID != nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connection = try await connect(chosen, folder, sessionID)
        guard generation == version, !cancelling else {
          await connection.stop("cancelled before the question was sent")
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
        arm(startupLimit)
        connection.prompt(prompt, settings: chosen)
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
  }
  /// The CLI no longer has the session (deleted or expired): the question starts a new one, and the
  /// answers already shown stay. Both CLIs say so at once (checked 16 Nov 2026: Claude Code 2.1.325
  /// in 0.8 s, codex-cli 0.167.1 in 0.1 s).
  private func startAfresh() {
    release(connection, "resume failed; starting afresh")
    connection = nil
    acceptingUpdates = false
    sessionID = nil
    notice = "Earlier context was not available"
    launch()
    onChange?()
  }
  /// A turn that never starts or never ends fails instead of waiting forever.
  private func arm(_ limit: Duration) {
    deadline?.cancel()
    let version = generation
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: limit) } catch { return }
      guard let self, generation == version, busy else { return }
      fail(
        "\(chosen.agent.product) took too long. Check that it works in Terminal, then try again.",
        outcome: "timeout after \(limit)")
    }
  }
  /// The turn failed: show why and end the turn. `outcome` is what the run's log says if the CLI
  /// itself said nothing about it.
  private func fail(_ message: String, outcome: String? = nil) {
    status = message
    problem = message
    finishTurn(outcome ?? "failed: \(message)")
  }

  private func receive(_ event: AgentEvent) {
    // A CLI waiting on a permission is silent until the user answers, which may take until `retention`.
    if permissions.isEmpty { arm(turnLimit) }
    switch event {
    case .session(let id):
      sessionID = id
      resuming = false
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
      // The answer is what follows the last tool call; what came before it was narration.
      if !answer.isEmpty || !pendingAnswer.isEmpty {
        narration = answer + pendingAnswer
        answer = ""
        pendingAnswer = ""
      }
      messageID = nil
      status = title
    case .permission(let permission):
      guard acceptingUpdates, !cancelling else {
        connection?.decide(permission.id, allow: false)
        return
      }
      permissions.append(permission)
      deadline?.cancel()
      if isHidden { expirePermissions() }
    case .finished(let cancelled):
      guard busy else { return }
      status = cancelled ? "Cancelled" : "Ready for a follow-up"
      finishTurn()
      return
    case .failed(let message):
      // A process that ended after its turn is not an error.
      guard busy else { return }
      if resuming, !cancelling { return startAfresh() }
      fail(message)
      return
    }
    onChange?()
  }
  func decide(_ allow: Bool) {
    guard let permission = permissions.first else { return }
    connection?.decide(permission.id, allow: allow)
    permissions.removeFirst()
    // The last one answered: silence counts again.
    if permissions.isEmpty, busy, !cancelling { arm(turnLimit) }
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
      await release(old, "cancelled; the CLI did not stop in time").value
      guard generation == cancelledVersion else { return }
      status = "Cancelled"
      finishTurn()
    }
    onChange?()
  }
  /// The turn is over, however it ended: its process ends with it.
  private func finishTurn(_ outcome: String = "turn ended") {
    settleAnswer()
    declineAll()
    busy = false
    acceptingUpdates = false
    cancelling = false
    lastActivity = Date()
    cancelDeadline?.cancel()
    deadline?.cancel()
    release(connection, outcome)
    connection = nil
    saveRun()
    onChange?()
  }
  /// The answer as the turn leaves it: what was held back, or the narration when nothing followed it.
  private func settleAnswer() {
    publishAnswer()
    if answer.isEmpty { answer = narration }
  }
  /// Saves the run with every turn it holds to Agent History.
  private func saveRun() {
    history?.save(
      AgentHistory.Run(
        id: runID, agent: chosen.agent, session: sessionID, used: Date(), source: runSource,
        turns: previous + [Turn(question: question, answer: answer)]))
  }
  /// Every pending permission is refused, so the CLI is never left waiting on one.
  private func declineAll() {
    while !permissions.isEmpty { decide(false) }
  }
  /// Stops a connection that is let go, in the order they were let go. `shutdown` waits for it.
  @discardableResult
  private func release(_ old: (any AgentConnection)?, _ reason: String) -> Task<Void, Never> {
    let before = teardown
    let stopping = Task {
      await before?.value
      await old?.stop(reason)
    }
    teardown = stopping
    return stopping
  }
  /// Ends the conversation. A turn still running ends with it and is saved as a cancelled one would be,
  /// with its answer so far.
  func reset() {
    if busy {
      settleAnswer()
      saveRun()
    }
    generation += 1
    task?.cancel()
    cancelDeadline?.cancel()
    permissionExpiry?.cancel()
    declineAll()
    deadline?.cancel()
    release(connection, "conversation reset or app quit")
    connection = nil
    active = false
    previous = []
    continuing = false
    busy = false
    sessionID = nil
    runID = UUID().uuidString
    runSource = nil
    reopened = nil
    notice = nil
    resuming = false
    source = nil
    answer = ""
    pendingAnswer = ""
    narration = ""
    messageID = nil
    question = ""
    status = ""
    problem = nil
    acceptingUpdates = false
    cancelling = false
    onChange?()
  }
  /// Reopens a run from Agent History as it was left: its last answer under its question, the earlier
  /// turns kept for the next save, and Continuing conversation. A follow-up resumes its session.
  func restore(_ run: AgentHistory.Run, settings: AgentConfiguration) {
    reset()
    guard let last = run.turns.last else { return }
    chosen = settings
    runID = run.id
    runSource = run.source
    reopened = run.agent
    sessionID = run.session
    previous = Array(run.turns.dropLast())
    question = last.question
    source = run.turns.count == 1 ? run.source : nil
    answer = last.answer
    turnID = UUID().uuidString
    status = "Ready for a follow-up"
    active = true
    continuing = true
    lastActivity = Date()
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
