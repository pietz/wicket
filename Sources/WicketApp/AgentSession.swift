import Foundation
import Observation

/// When the current turn began, started showing an answer, and entered its ending.
struct AgentTurnTiming: Equatable {
  let start: Date
  var streamingAt: Date?
  var ending: Ending?

  enum Ending: Equatable {
    case done(Date)
    case cancelled(Date)
  }
}

/// Owns a conversation: one CLI process per question, which ends with the turn, and the session ID
/// that the next question resumes. No window dependency.
@MainActor @Observable
final class AgentSession {
  typealias Turn = AgentHistory.Run.Turn
  /// The last ten earlier turns, which Agent History saves with the last one while their run is kept.
  private(set) var previous: [Turn] = []
  private(set) var continuing = false
  var agentName: String { chosen.agent.title }
  private(set) var active = false
  private(set) var busy = false
  private(set) var turnID = UUID().uuidString
  private(set) var turnTiming: AgentTurnTiming?
  private(set) var question = ""
  /// The command the question was asked from, whose context went with it; nil for a follow-up.
  private(set) var source: String?
  private(set) var answer = ""
  /// The answer as a page, with what it lets the user act on where it stands. Never a run action. Built
  /// when read and kept while the answer stays as it is: building reads the whole answer.
  var page: Page {
    if let built, built.streaming == busy, built.body == answer { return built.page }
    let page = Page(body: answer, runs: false, streaming: busy)
    built = (answer, busy, page)
    return page
  }
  @ObservationIgnored private var built: (body: String, streaming: Bool, page: Page)?
  private(set) var status = ""
  private(set) var problem: String?
  private(set) var permissions: [AgentPermission] = []
  /// Whether speech may go into the input now: not while a turn runs or a permission waits.
  var takesSpeech: Bool { !busy && permissions.isEmpty }
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
  /// One quiet line under the question: a reopened run's follow-ups are read-only (`restore`), or the
  /// session could not be resumed, so the answer started afresh.
  private(set) var notice: String?
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
  private var cancelDeadline: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  /// Every connection that was let go and is still stopping, so `shutdown` can wait for it.
  private var teardown: Task<Void, Never>?
  /// When the panel last went off screen. Nil while it is visible.
  private var hiddenAt: Date?
  var cancelGrace: Duration = .seconds(3)
  /// Nothing at all from a CLI that started, then nothing for this long during the turn: a working
  /// agent, even one whose command prints for an hour, is never cut off, a hung one is. While a
  /// permission waits for the user, no limit runs.
  var startupLimit: Duration = .seconds(30)
  var turnLimit: Duration = .seconds(600)
  /// Starts the CLI for one question with these settings in the folder, resuming the session ID if there is one.
  var connect: (AgentConfiguration, URL, String?) async throws -> any AgentConnection

  init(folder: URL, log: AgentLog = .standard()) {
    self.folder = folder
    connect = { try AgentCLI.connect($0, folder: $1, resume: $2, log: log) }
  }
  /// A running turn (including a permission prompt) or an unseen result always reopens. After it has
  /// been shown, the next hide starts a fresh retention window. Only an idle conversation expires,
  /// and only on reopen. The CLI ends with each turn, and finished turns stay in Agent History.
  func reopen(now: Date, retention: AgentConfiguration.AnswerRetention) -> Bool {
    guard active, !busy, !waiting, let hiddenAt, retention != .never,
      retention == .immediately || now.timeIntervalSince(hiddenAt) > TimeInterval(retention.rawValue)
    else {
      return false
    }
    reset()
    return true
  }
  func hidden(now: Date = Date()) {
    hiddenAt = hiddenAt ?? now
    if active { continuing = true }
    if !permissions.isEmpty { waiting = true }
  }
  /// Only a visible panel clears the dot and starts a new visit. The Settings hotkey goes through
  /// `reopen` on its way to Settings, leaving the panel hidden.
  func seen() {
    hiddenAt = nil
    waiting = false
  }
  /// Something waits for the user while the panel is hidden, a permission or an ended turn; the menu bar
  /// icon shows a dot until the panel shows again.
  private(set) var waiting = false
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
    cancelDeadline?.cancel()
    turnID = UUID().uuidString
    turnTiming = AgentTurnTiming(start: Date())
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
    launch()
    onChange?()
  }
  /// Starts the CLI for the current question, resuming the session if there is one.
  private func launch() {
    generation += 1
    let version = generation
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connection = try await connect(chosen, folder, sessionID)
        guard generation == version, !cancelling else {
          await connection.stop("cancelled before the question was sent")
          guard generation == version, busy else { return }
          finishTurn(cancelled: true)
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
        onChange?()
      } catch {
        guard generation == version else { return }
        if cancelling {
          finishTurn(cancelled: true)
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
    release("resume failed; starting afresh")
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
    // Another tool's update does not restart the limit while a permission waits on the user.
    if permissions.isEmpty { arm(turnLimit) }
    switch event {
    case .activity:
      return
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
          if turnTiming?.streamingAt == nil { turnTiming?.streamingAt = Date() }
          answer += text
          return drawSoon()
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
        // The light dims for the answer, not for narration before a tool.
        turnTiming?.streamingAt = nil
      }
      messageID = nil
      status = title
    case .permission(let permission):
      guard acceptingUpdates, !cancelling else {
        connection?.decide(permission.id, allow: false)
        return
      }
      permissions.append(permission)
      if hiddenAt != nil { waiting = true }
      // The CLI is silent while it waits for the user's decision.
      deadline?.cancel()
    case .finished(let cancelled):
      guard busy else { return }
      finishTurn(cancelled: cancelled)
      return
    case .failed(let message):
      // A process that ended after its turn is not an error.
      guard busy else { return }
      fail(message)
      return
    case .sessionMissing(let message):
      guard busy else { return }
      // Any other failure keeps the session: the next question resumes it again.
      if sessionID != nil, !cancelling { return startAfresh() }
      fail(message)
      return
    }
    onChange?()
  }
  /// A streamed answer is drawn at most every 40 ms, as often as the renderer takes it, since drawing
  /// builds its page. Anything else draws at once, the end of the turn included.
  private func drawSoon() {
    guard drawing == nil else { return }
    drawing = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(40))
      guard let self else { return }
      drawing = nil
      onChange?()
    }
  }
  @ObservationIgnored private var drawing: Task<Void, Never>?
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
    turnTiming?.ending = .cancelled(Date())
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
      await release("cancelled; the CLI did not stop in time").value
      guard generation == cancelledVersion else { return }
      finishTurn(cancelled: true)
    }
    onChange?()
  }
  /// The turn is over and its process ends with it. A failure has already set the footer's status.
  private func finishTurn(_ outcome: String = "turn ended", cancelled: Bool? = nil) {
    // A CLI can report a completed turn after the user cancelled it; the user's cancel wins.
    let cancelled = cancelled.map { $0 || cancelling }
    if let cancelled { status = cancelled ? "Cancelled" : "Ready for a follow-up" }
    if turnTiming?.ending == nil {
      let now = Date()
      turnTiming?.ending = cancelled == true ? .cancelled(now) : .done(now)
    }
    // A turn the user cancelled has nothing to come back for; one cut off at the size limit does.
    waiting = hiddenAt != nil && (!cancelling || problem != nil)
    saveTurn()
    declineAll()
    busy = false
    cancelling = false
    cancelDeadline?.cancel()
    deadline?.cancel()
    release(outcome)
    onChange?()
  }
  /// Settles the answer as the turn leaves it (what was held back, or the narration when nothing followed
  /// it) and saves the run with every turn it holds to Agent History.
  private func saveTurn() {
    publishAnswer()
    if answer.isEmpty { answer = narration }
    // Earlier turns were saved, but their run is gone (deleted or cleared): they stay deleted, and this
    // turn starts a new run. The screen keeps what it shows.
    if !previous.isEmpty, let history, history.run(runID) == nil {
      runID = UUID().uuidString
      runSource = source
      previous = []
    }
    history?.save(
      AgentHistory.Run(
        id: runID, agent: chosen.agent, session: sessionID, used: Date(), source: runSource,
        turns: previous + [Turn(question: question, answer: answer)]))
  }
  /// Every pending permission is refused, so the CLI is never left waiting on one.
  private func declineAll() {
    while !permissions.isEmpty { decide(false) }
  }
  /// Lets the connection go: its updates are ignored from now on, and it stops after any connection let
  /// go before it. `shutdown` waits for it.
  @discardableResult
  private func release(_ reason: String) -> Task<Void, Never> {
    let old = connection
    connection = nil
    acceptingUpdates = false
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
    if busy { saveTurn() }
    generation += 1
    task?.cancel()
    cancelDeadline?.cancel()
    declineAll()
    deadline?.cancel()
    release("conversation reset or app quit")
    active = false
    previous = []
    continuing = false
    busy = false
    waiting = false
    turnTiming = nil
    sessionID = nil
    runID = UUID().uuidString
    runSource = nil
    reopened = nil
    notice = nil
    source = nil
    answer = ""
    pendingAnswer = ""
    narration = ""
    messageID = nil
    question = ""
    status = ""
    problem = nil
    cancelling = false
    onChange?()
  }
  /// Reopens a run from Agent History as it was left: its last answer under its question, the earlier
  /// turns kept for the next save, and Continuing conversation. A follow-up resumes its session.
  func restore(_ run: AgentHistory.Run, settings: AgentConfiguration, notice: String?) {
    reset()
    guard let last = run.turns.last else { return }
    self.notice = notice
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
