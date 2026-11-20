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
  /// The arguments the user fills in, in the slots after the input.
  let arguments: [ExtensionManifest.Argument]
  /// It runs on Return only (`submit` in its manifest): typing, voice and refreshes leave its view alone,
  /// the input has the first say, and Return sends what is typed and filled in.
  let submits: Bool
  /// A question asked from it goes with what it shows (`agentContext`).
  let asksAbout: Bool
}

/// A request to a command: the input and arguments it was made with, and why it was made.
struct CommandScreenRequest {
  let input: String
  let arguments: [String: String]
  let cause: CommandScreen.Cause
  /// The request as an extension's program and a host command receive it.
  var provider: ProviderRequest {
    ProviderRequest(input: input, arguments: arguments, submitted: cause == .submission)
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
  /// Why it failed, shown instead of a view.
  case problem(String)
  /// A submitted request is done (`ProviderView.close`): the panel hides without showing it, as the user
  /// hiding it would; the effect (a moved window) is the feedback.
  case close
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
  enum Cause { case rerun, address, submission }
  /// A view with the input and arguments of the request it answered.
  struct Shown {
    var view = ProviderView()
    var input = ""
    var arguments: [String: String] = [:]
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
  private(set) var busy = false
  private(set) var turn = UUID().uuidString

  init(_ behavior: any CommandScreenBehavior, arguments: [String: String] = [:]) {
    self.behavior = behavior
    screen.fill(arguments)
  }

  /// Entered from an address: its next request runs, submitted when the user activated it.
  mutating func enter(submitted: Bool) { next = submitted ? .submission : .address }
  /// The request what is typed makes now.
  func request(input: String) -> CommandScreenRequest {
    CommandScreenRequest(input: input, arguments: screen.arguments, cause: next)
  }
  /// A request is being answered; every later one is a rerun.
  mutating func begin() { next = .rerun }
  /// A process answers it.
  mutating func run() {
    problem = nil
    busy = true
  }
  /// Its request stopped: nothing is running.
  mutating func stop() { busy = false }
  /// What answered `request`: a list ordered by what is typed, or a page. `remembered`: the user did not
  /// cause the request by typing, so the view becomes its context.
  mutating func show(
    _ view: ProviderView, page: Page?, for request: CommandScreenRequest, turn: String, remembered: Bool
  ) {
    self.turn = turn
    shown = Shown(view: view, input: request.input, arguments: request.arguments)
    if remembered { context = shown }
    self.page = page
    problem = nil
    busy = false
    screen.rows = page == nil ? Ranking.order(view.items, provider: id, query: request.input) : []
  }
  /// Its request failed: why, instead of a view.
  mutating func fail(_ problem: String, remembered: Bool) {
    if remembered { context = nil }
    self.problem = problem
    busy = false
    screen.rows = []
  }
  /// It cannot run: why, instead of a view. Back on or back again, it runs as when it is entered.
  mutating func unavailable(_ problem: String) {
    next = .address
    context = nil
    self.problem = problem
    screen.rows = []
  }

  /// Its Markdown body, unless it failed.
  var body: String? { problem == nil ? shown.view.body : nil }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { body == nil ? [] : shown.view.actions }
  /// With nothing selected, what Return sends in a submit command: what is typed, and the declared
  /// arguments, including a value a run action set under a declared name. What it set under any other
  /// name stays out, or a Delete chosen once would be sent again with every later Return; the contract
  /// keeps confirmations to such names. Nil for any other command.
  func submission(input: String) -> Result? {
    guard let descriptor, descriptor.submits else { return nil }
    let declared = Set(descriptor.arguments.map(\.name))
    return Result(
      provider: id,
      row: Row(
        id: "submit", title: descriptor.name,
        actions: [
          .run(Address(input: input, arguments: screen.arguments.filter { declared.contains($0.key) }))
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
    if !shown.arguments.isEmpty { asked += ", arguments \(json(shown.arguments))" }
    text = "<context>\n\(asked).\nIt showed:\n\(view)\n</context>"
  }
}
