import Foundation

/// What is selected in a list or on a page: a row by its stable id. Until the user chooses one
/// (`touched`), the selection follows the first row; a new input or screen starts it over (`reset`).
/// `previous` is the rows it was last reconciled with, so a chosen row that went away leaves the
/// selection at its place (`moved`).
struct Selection {
  var id: String?
  var touched = false
  /// On the row that took the place of a chosen one that went away: the user did not choose it.
  var moved = false
  var reset = true
  var previous: [String] = []
  /// Follows the rows shown now. Untouched, it is on the first row, or on none while the input has the
  /// first say (`waits`). A chosen row that went away leaves it at that row's place, except on a page,
  /// where it goes with its target, so Return never moves to a neighbor, and while sources are still
  /// `pending`, when the row may come back.
  mutating func follow(_ rows: [String], waits: Bool, onPage: Bool, pending: Bool) {
    if reset { touched = false }
    if !touched {
      moved = false
      id = waits ? nil : rows.first
    } else if let chosen = id, !rows.contains(chosen) {
      if onPage {
        touched = false
        id = nil
        reset = false
        return
      }
      if pending {
        reset = false
        return
      }
      let index = previous.firstIndex(of: chosen) ?? 0
      id = rows.isEmpty ? nil : rows[min(index, rows.count - 1)]
      moved = true
    }
    reset = false
    previous = rows
  }
  /// The user chose the row it is on.
  var picked: Bool { touched && !moved }
  mutating func pick(_ id: String?) {
    self.id = id
    touched = true
    moved = false
  }
}

/// One visit to a screen: the root's search, a command, or the conversation. What is typed there, the
/// values filled in, what is selected, its list and the details opened over its page. A screen under
/// another one keeps all of it, so coming back to it needs no snapshot.
struct Screen {
  var input = ""
  /// A command's argument values. At the root, the values filled in for the selected command row, which
  /// go when that selection moves (`draftFollowsSelection`).
  private(set) var arguments: [String: String] = [:]
  private(set) var selection = Selection()
  /// The root's results or a command's items.
  var rows: [Result] = []
  /// Items' contents opened as pages over this screen's page, the last one shown.
  private(set) var details: [Detail] = []
  /// The arguments are a draft for the selected row (the root's), not the screen's own.
  var draftFollowsSelection = false

  init(arguments: [String: String] = [:], draftFollowsSelection: Bool = false) {
    self.arguments = arguments
    self.draftFollowsSelection = draftFollowsSelection
  }
  /// Fills in an argument; empty is unfilled.
  mutating func fill(_ name: String, with value: String) { arguments[name] = value.isEmpty ? nil : value }
  mutating func fill(_ arguments: [String: String]) { self.arguments = arguments }

  /// The details open over the page whose turn is `base`; those of an earlier page are not.
  func details(over base: String) -> [Detail] { details.first?.base == base ? details : [] }
  /// Opens a detail over the page whose turn is `base`, after those already open over it.
  mutating func open(_ detail: Detail) { details = details(over: detail.base) + [detail] }
  /// Escape in a detail: the page or detail under it is as the user left it.
  mutating func closeDetail(over base: String) { details = Array(details(over: base).dropLast()) }
  /// What the arrow keys move here: the last detail's selection over the page `base`, else the screen's.
  func selection(over base: String) -> Selection { details(over: base).last?.selection ?? selection }
  mutating func select(_ new: Selection, over base: String) {
    if !details(over: base).isEmpty {
      details[details.count - 1].selection = new
      return
    }
    if draftFollowsSelection, new.id != selection.id { arguments = [:] }
    selection = new
  }
  /// An edit starts the selection over: on the screen, which a rerun's new page shows, and in the detail
  /// open over it, which a submit command's edit leaves open, so Return sends the edited request.
  mutating func startSelectionOver(over base: String) {
    selection.reset = true
    if !details(over: base).isEmpty { details[details.count - 1].selection.reset = true }
  }
  /// A new screen, or one shown again started over: its selection follows the first row again.
  mutating func startSelectionOver() { selection.reset = true }
}

/// An item's content opened as its own page over the page it came from, with a selection of its own:
/// Escape drops it, and the page under it is as the user left it. A detail belongs to one page (`base`),
/// so a new answer or view leaves it.
struct Detail {
  let page: Page
  let base: String
  /// Derived from the base's turn, so the renderer keeps each page's scroll position.
  let turn: String
  var selection = Selection(reset: false)
}

/// The action panel (⌘K): one row's actions as rows of their own, over the screen it was opened on, with
/// a selection of its own. The row is captured when the panel opens, and what is chosen runs from it.
struct ActionPresentation {
  let source: Result
  let rows: [Result]
  var selection = Selection()
}

/// The agent's screen, over the root or the open command, which stay under it as they were: its own
/// input, selection and details, and what leaving it does.
struct AgentScreen {
  var screen = Screen()
  let back: Back
  /// Whether the question header shows all of a long question.
  var expanded = false
  enum Back {
    /// The empty question ⌘↩ opened: Escape before sending shows the screen under it exactly as it was,
    /// with nothing run again, and its first question tells the agent what that screen showed then.
    case reveal(AgentContext?)
    /// A conversation (sent, reopened from Agent History, or prefilled by the `agent` action): ending it
    /// goes back to the screen under it with a blank input, its request run again and its selection
    /// started over.
    case refresh
  }
}

/// The agent's screen as the panel draws it and routes keys by (`Navigator.agentScreen`): the session's
/// turn and its first permission, which the session keeps alive and expires, with this visit's own state.
struct AgentPresentation: Equatable {
  let question: String
  /// The command the question was asked from, whose context went with it.
  let source: String?
  let notice: String?
  let status: String
  let problem: String?
  /// The permission the card asks about; the others wait behind it.
  let permission: AgentPermission?
  let agentName: String
  let folder: URL
  /// A turn runs, `working` until its answer begins: the answer area shows its own spinner meanwhile.
  let busy: Bool
  let working: Bool
  let streaming: Bool
  let expanded: Bool
  /// The footer's line: what the last action could not do (`Navigator.actionProblem`), else that a kept or
  /// reopened conversation is ready for a follow-up, else its status, unless the answer area shows that.
  let footer: String
  /// The footer's spinner: a turn runs and the answer area isn't showing its own.
  let footerBusy: Bool
  /// `covered`: the actions list hides the conversation, so the answer area shows nothing.
  @MainActor init(
    _ session: AgentSession, _ screen: AgentScreen, actionProblem: String?, covered: Bool = false
  ) {
    question = session.question
    source = session.source
    notice = session.notice
    status = session.status
    problem = session.problem
    permission = session.permissions.first
    agentName = session.agentName
    folder = session.folder
    busy = session.busy
    working = session.busy && session.answer.isEmpty
    streaming = session.streaming
    expanded = screen.expanded
    let continuing = session.continuing && !session.busy && !session.question.isEmpty
    let answerShowsStatus = working && !covered
    footer = actionProblem ?? (continuing ? "Continuing conversation" : answerShowsStatus ? "" : status)
    footerBusy = busy && !answerShowsStatus
  }
}
