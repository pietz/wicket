import Foundation

/// What a command does with the requests of its screen: an extension's command or a host command, as
/// `CommandDirectory.behavior` resolves it. The navigator moves between screens, stages what arrives and
/// routes the keys; what a request takes, what it is answered with and what the agent learns from it are
/// the behavior's. Each visit (`CommandScreen`) holds its own state and the behavior.
@MainActor protocol CommandScreenBehavior {
  var id: String { get }
  /// Nil once the command is gone, such as a removed extension.
  var descriptor: CommandDescriptor? { get }
  /// What answering a request takes. Synchronous, so what needs no process shows before Return returns.
  func work(for request: CommandScreenRequest) -> CommandWork
  /// What a question asked from the screen tells the agent it showed; nil for the host's own commands.
  func agentContext(from shown: CommandScreen.Shown) -> AgentContext?
}

/// What a command is to its screen and the keys.
struct CommandDescriptor {
  /// For the input's placeholder and the footer.
  let name: String
  let fields: [ExtensionManifest.Field]
  var inputField: ExtensionManifest.Field? { fields.first { $0.type == .text } }
  /// It runs on Return only (`submit` in its manifest): typing, voice and refreshes leave its view alone,
  /// the input has the first say, and Return sends what is typed and filled in.
  let submits: Bool
  /// What Return sends there is a hidden run (`Address.hidden`).
  var hidden = false
  /// A question asked from it goes with what it shows (`agentContext`).
  let asksAbout: Bool
}

/// A request to a command: the input and fields it was made with, and why it was made.
struct CommandScreenRequest {
  let input: String
  var fields: [String: String]
  var action: String? = nil
  let cause: CommandScreen.Cause
  var fieldChange: Page.Field.Change? = nil
  /// The request as an extension's program and a host command receive it.
  var provider: ProviderRequest {
    ProviderRequest(input: input, fields: fields, action: action, submitted: cause == .submission)
  }
}

/// What answering a request takes (`CommandScreenBehavior.work`).
enum CommandWork {
  /// The view shown stays and nothing runs.
  case keepView
  /// The command was removed or switched off: why, shown instead of a view.
  case unavailable(String)
  /// Answered at once, without a process: an extension's manifest items or a host command's list.
  case immediate(CommandOutcome)
  /// A process answers.
  case deferred(@MainActor () async -> CommandOutcome)
}

/// What a request was answered with. The navigator takes it only for the visit and the run that asked.
enum CommandOutcome {
  /// A list, or a page with its items after its body.
  case view(ProviderView)
  /// A full report in place of a view, or a summary in the footer while queued work continues.
  case problem(String, summary: String)
  /// A run from Agent History opens as a conversation over the screen, which Escape returns to.
  case restore(AgentHistory.Run)
}

/// One visit to a command: its behavior, what is typed and filled in there with its selection and details
/// (`screen`), what it shows and what it last showed the agent. The navigator stages the visit and hands
/// it what its requests are answered with; the visit writes its own state.
@MainActor struct CommandScreen {
  let behavior: any CommandScreenBehavior
  /// This visit: an answer counts only for the visit that asked (`Navigator.answer`).
  let visit = UUID()
  var id: String { behavior.id }
  var descriptor: CommandDescriptor? { behavior.descriptor }
  var screen = Screen()
  /// What the next request answers. Going to an address runs it even in a submit command, and the
  /// user's activation makes it submitted; every later request is a rerun.
  private(set) var next = Cause.address
  private var action: String?
  private var replacingFields = false
  /// A link or root pattern can supply a command query while the search bar holds an agent draft.
  private var providerInput = ""
  var input: String {
    get { descriptor?.inputField == nil ? screen.input : providerInput }
    set {
      if descriptor?.inputField == nil { screen.input = newValue } else { providerInput = newValue }
    }
  }
  enum Cause { case rerun, address, submission }
  /// A view with the input and fields of the request it answered.
  struct Shown {
    var view = ProviderView()
    var input = ""
    var fields: [String: String] = [:]
  }
  /// What the command shows now.
  private(set) var shown = Shown()
  /// What a typed question tells the agent the command showed (`AgentContext`): the last view whose
  /// request the user did not cause by typing. Typing reruns never replace it, so a question typed into a
  /// command that is not `submit` sends the view it was asked about, not the rerun for its own text. Nil
  /// until such a request is answered, and after one fails.
  private(set) var context: Shown?
  /// The view's body as a page, with its items after it; nil for a list.
  private(set) var page: Page?
  private(set) var problem: String?
  /// A failed form leaves its values for retries until the command returns a new view.
  private var failedCanvasValues: [String: String] = [:]
  /// A link or replay cleared the shown form's values; if its request fails, a retry must not restore them.
  private var canvasCleared = false
  private var runningCause: Cause?
  var busy: Bool { runningCause != nil }
  private(set) var runningAction = false
  var runningSubmission: Bool { runningCause == .submission }
  private(set) var turn = UUID().uuidString
  private var canvasEdits: [String: String] = [:]
  private var submissions: [CommandScreenRequest] = []
  private var pendingChange: Page.Field.Change?
  private var pendingRefresh: Bool?
  var awaitsRerun: Bool {
    runningCause == .rerun || runningSubmission && (pendingChange != nil || pendingRefresh != nil)
  }

  init(_ behavior: any CommandScreenBehavior) {
    self.behavior = behavior
  }

  /// Applies an address to this visit. `replacingFields` restores the address's exact field set (used when
  /// replaying a permission-gated request so edits made while the gate was visible do not leak in).
  /// Returns the name of an invalid canvas override, leaving the visit as it was.
  @discardableResult
  mutating func enter(
    _ address: Address, submitted: Bool, replacingFields: Bool = false
  ) -> String? {
    let submitting = submitted && !address.link
    let overrides = address.fields ?? [:]
    if submitting, !replacingFields,
      let invalid = overrides.first(where: { name, value in
        guard let field = page?.fields[name] else { return false }
        return field.canonical(value) == nil
      })
    {
      return invalid.key
    }
    next = submitting ? .submission : .address
    action = next == .submission ? address.action : nil
    self.replacingFields = replacingFields
    let field = descriptor?.inputField
    if address.link || replacingFields {
      screen.fill([:])
      canvasEdits.removeAll()
      failedCanvasValues.removeAll()
      canvasCleared = true
    }
    for (name, value) in overrides where name != field?.name {
      if submitting, !replacingFields, page?.fields[name] != nil {
        page?.fill(name, with: value)
        canvasEdits[name] = nil
      } else {
        if failedCanvasValues.removeValue(forKey: name) != nil { canvasEdits[name] = nil }
        screen.fill(name, with: value)
      }
    }
    providerInput =
      field.flatMap { overrides[$0.name] } ?? address.input ?? (replacingFields ? "" : providerInput)
    if let field { screen.fill(field.name, with: "") }
    return nil
  }

  func request() -> CommandScreenRequest {
    var fields = screen.fields
    if next != .address, !replacingFields {
      fields.merge(page?.fields.mapValues(\.value) ?? failedCanvasValues) { _, canvas in canvas }
    }
    if let field = descriptor?.inputField { fields[field.name] = providerInput.isEmpty ? nil : providerInput }
    return CommandScreenRequest(
      input: providerInput, fields: fields, action: action, cause: next)
  }

  /// Keeps the latest local edit visible and stages only the work this control calls for.
  mutating func edit(_ change: Page.Field.Change) -> Bool {
    guard let field = page?.fields[change.name], let value = field.canonical(change.value) else {
      return false
    }
    if change.phase == .preview {
      guard case .slider = field.control else { return false }
    }
    page?.fill(change.name, with: value)
    canvasEdits[change.name] = value
    let change = Page.Field.Change(name: change.name, value: value, phase: change.phase)
    if change.phase == .commit, let action = field.action {
      let current = request()
      enqueue(
        CommandScreenRequest(
          input: current.input, fields: current.fields, action: action, cause: .submission,
          fieldChange: change))
      // The submitted value also answers this field's last deferred preview.
      if pendingChange?.name == change.name { pendingChange = nil }
    } else if descriptor?.submits == false {
      pendingChange = change
    }
    return true
  }

  mutating func enqueue(_ request: CommandScreenRequest) {
    if let name = request.fieldChange?.name,
      let index = submissions.indices.reversed().prefix(while: { submissions[$0].fieldChange != nil })
        .first(where: { submissions[$0].fieldChange?.name == name })
    {
      submissions[index] = request
    } else {
      submissions.append(request)
    }
  }

  mutating func refreshAfterSubmission(typed: Bool) {
    pendingRefresh = (pendingRefresh ?? true) && typed
  }

  mutating func takePending() -> (CommandScreenRequest, typed: Bool)? {
    if !submissions.isEmpty {
      var request = submissions.removeFirst()
      if let change = request.fieldChange {
        request.fields.merge(page?.fields.mapValues(\.value) ?? [:]) { _, latest in latest }
        request.fields[change.name] = change.value
      }
      return (request, false)
    }
    guard pendingChange != nil || pendingRefresh != nil else { return nil }
    var request = request()
    request.fieldChange = pendingChange
    let typed = pendingChange == nil && pendingRefresh == true
    pendingChange = nil
    pendingRefresh = nil
    return (request, typed)
  }

  mutating func discardPending() {
    submissions.removeAll()
    pendingChange = nil
    pendingRefresh = nil
  }
  /// A request is being answered; every later one is a rerun.
  mutating func begin(_ request: CommandScreenRequest? = nil) {
    next = .rerun
    action = nil
    replacingFields = false
    if let request {
      canvasEdits = canvasEdits.filter { $0.value != request.fields[$0.key] }
    }
  }
  /// A process answers it.
  mutating func run(_ request: CommandScreenRequest) {
    problem = nil
    runningCause = request.cause
    runningAction = request.action != nil
  }
  /// Its request stopped: nothing is running.
  mutating func stop() {
    runningCause = nil
    runningAction = false
  }

  func makePage(_ view: ProviderView) -> Page? {
    guard let body = view.body else { return nil }
    var page = Page(body: body, items: view.items, runs: true, fieldSlots: descriptor?.fields)
    page.targetRevision = UUID().uuidString
    return page
  }
  /// What answered `request`: a list ordered by what is typed, or a page. `remembered`: the user did not
  /// cause the request by typing, so the view becomes its context.
  mutating func show(
    _ view: ProviderView, page: Page?, for request: CommandScreenRequest, turn: String, remembered: Bool
  ) {
    self.turn = turn
    shown = Shown(view: view, input: request.input, fields: request.fields)
    if remembered { context = shown }
    self.page = page
    failedCanvasValues.removeAll()
    canvasCleared = false
    // Edits still waiting for an explicit submit survive another field's reply.
    canvasEdits = canvasEdits.filter { name, value in page?.fields[name]?.canonical(value) != nil }
    for (name, value) in canvasEdits { self.page?.fill(name, with: value) }
    if let page {
      for name in page.fields.keys { screen.fill(name, with: "") }
    }
    problem = nil
    stop()
    screen.rows = page == nil ? Ranking.order(view.items, provider: id, query: request.input) : []
    if Permissions.isGate(screen.rows) {
      screen.startSelectionOver()
    } else if request.action != nil, !screen.selection(over: turn).touched,
      case .run(let address)? = screen.rows.first?.row.actions.first?.kind, address.action != nil
    {
      screen.select(Selection(touched: true, reset: false), over: turn)
    }
  }
  /// Its request failed: why, instead of a view.
  mutating func fail(_ problem: String, remembered: Bool) {
    if remembered { context = nil }
    if let fields = page?.fields, !fields.isEmpty {
      failedCanvasValues = canvasCleared ? [:] : fields.mapValues(\.value)
      page = nil
    }
    self.problem = problem
    stop()
    screen.rows = []
  }
  /// It cannot run: why, instead of a view. Back on or back again, it runs as when it is entered.
  mutating func unavailable(_ problem: String) {
    next = .address
    action = nil
    fail(problem, remembered: true)
  }

  /// Its visible Markdown body.
  var body: String? { problem == nil && page != nil ? shown.view.body : nil }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { body == nil ? [] : shown.view.actions }
  /// With nothing selected, Return can submit the current fields when the command owns the input.
  func submission() -> Result? {
    guard let descriptor, descriptor.submits, descriptor.inputField != nil else { return nil }
    return Result(
      provider: id,
      row: Row(
        id: "submit", title: descriptor.name,
        actions: [
          .run(Address(input: providerInput, hidden: descriptor.hidden))
        ]))
  }
  /// What goes with a question asked from here: for a typed question its `context`, else what it shows
  /// unless that is an error.
  private func shown(typed: Bool) -> Shown? { typed ? context : problem == nil ? shown : nil }
  func agentContext(typed: Bool) -> AgentContext? {
    shown(typed: typed).flatMap { behavior.agentContext(from: $0) }
  }
  /// The command's name when a question asked now would go with what it showed, for the footer.
  func asksAbout(typed: Bool) -> String? {
    guard let descriptor, descriptor.asksAbout, shown(typed: typed) != nil else { return nil }
    return descriptor.name
  }
}

/// What an open extension command showed, as a `<context>` block for the agent's first question, and the
/// command's name for the question header.
struct AgentContext {
  let text: String
  let name: String
  /// About 4 KB of the open view goes to the agent.
  static let limit = 4000
  /// The command and what it showed, as a `<context>` block, with the command's name for the header.
  init(_ owner: ExtensionCommand, shown: CommandScreen.Shown) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func json(_ value: some Encodable) -> String {
      String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
    struct Content: Encodable {
      let body: String?
      let items: [Row]
    }
    var view = json(Content(body: shown.view.body, items: shown.view.items))
    if view.count > Self.limit {
      view = String(view.prefix(Self.limit)) + "\n[cut: the view was longer than this]"
    }
    name = owner.manifest.name
    var asked =
      "The user asked from the \(name) command (\(owner.folder.path), folder `\(owner.folder.lastPathComponent)`)"
    asked += ", input \(json(shown.input))"
    if !shown.fields.isEmpty { asked += ", fields \(json(shown.fields))" }
    text = "<context>\n\(asked).\nIt showed:\n\(view)\n</context>"
  }
}
