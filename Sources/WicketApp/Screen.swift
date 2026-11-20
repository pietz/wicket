import Foundation

/// What is selected in a list or on a page: a row by its stable id. Until the user chooses one
/// (`touched`), the selection follows the first row; a new input or screen starts it over (`reset`).
/// `previous` is the rows it was last reconciled with, so a chosen row that went away leaves the
/// selection at its place.
struct Selection {
  var id: String?
  var touched = false
  var reset = true
  var previous: [String] = []
  /// Follows the rows shown now. Untouched, it is on the first row, or on none while the input has the
  /// first say (`waits`). A chosen row that went away leaves it at that row's place, except on a page,
  /// where it goes with its target, so Return never moves to a neighbor, and while sources are still
  /// `pending`, when the row may come back.
  mutating func follow(_ rows: [String], waits: Bool, onPage: Bool, pending: Bool) {
    if reset { touched = false }
    if !touched {
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
    }
    reset = false
    previous = rows
  }
}

/// One visit to a screen: the root's search, a command, or the conversation. What is typed there, the
/// values filled in, what is selected, its list and the details opened over its page. A screen under
/// another one keeps all of it, so coming back to it needs no snapshot.
struct Screen {
  var input = ""
  /// A command's argument values. At the root, the values filled in for the selected command row, which
  /// go when that selection moves.
  var arguments: [String: String] = [:]
  var selection = Selection()
  /// The root's results or a command's items.
  var rows: [Result] = []
  /// Items' contents opened as pages over this screen's page, the last one shown.
  var details: [Detail] = []
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

/// The command screen: an extension's, or a host command's (Clipboard History, Agent History).
struct CommandState {
  let id: String
  var screen = Screen()
  /// What the next request answers. Going to an address runs it even in a submit command, and the
  /// user's activation makes it submitted; every later request is a rerun.
  var next = Cause.address
  enum Cause { case rerun, address, submission }
  /// A view with the input and arguments of the request it answered.
  struct Shown {
    var view = ProviderView()
    var input = ""
    var arguments: [String: String] = [:]
  }
  /// What the command shows now.
  var shown = Shown()
  /// What a typed question tells the agent the command showed (`AgentContext`): the
  /// last view whose request the user did not cause by typing. Typing reruns never replace it, so a
  /// question typed into a command that is not `submit` sends the view it was asked about, not the
  /// rerun for its own text. Nil until such a request is answered, and after one fails.
  var context: Shown?
  /// The view's body as a page, with its items after it; nil for a list.
  var page: Page?
  var problem: String?
  var busy = false
  var turn = UUID().uuidString
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

/// What an open extension command showed, as a `<context>` block for the agent's first question, and the
/// command's name for the question header.
struct AgentContext {
  let text: String
  let name: String
  /// About 4 KB of the open view goes to the agent.
  static let limit = 4000
  /// The command and what it showed, as a `<context>` block, with the command's name for the header.
  init(_ owner: ExtensionCommand, shown: CommandState.Shown) {
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

/// The agent's screen as the panel draws it and routes keys by (`Navigator.agentScreen`): the session's
/// turn and its first permission, which the session keeps alive and expires, with this visit's own state.
@MainActor struct AgentPresentation {
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
  /// A kept or reopened conversation, ready for a follow-up.
  let continuing: Bool
  let streaming: Bool
  let expanded: Bool
  init(_ session: AgentSession, _ screen: AgentScreen) {
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
    continuing = session.continuing && !session.busy && !session.question.isEmpty
    streaming = session.streaming
    expanded = screen.expanded
  }
}
