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
  /// What a typed question tells the agent the command showed (`Navigator.commandContext`): the
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
}
