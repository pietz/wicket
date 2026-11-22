import Foundation

/// What the navigator asks of the panel it shows in (`PaletteController`): drawing what it committed, in
/// the same turn, so the native frame and the content change together; measuring a page before it shows;
/// and what leaves the screens.
@MainActor protocol PaletteSurface: AnyObject {
  /// Draws `presentation`, which `change` says what changed in.
  func present(_ change: PaletteChange, _ presentation: PalettePresentation)
  /// Renders and measures a page before it shows, so the card's height is known when it appears. The
  /// height is held for the page's turn until the navigator shows it (`PaletteChange.measured`): the page
  /// shown meanwhile keeps its own.
  func prepare(_ page: Page, turn: String) async -> PageMeasurement
  /// Whether the panel is up: a hidden run that finds something to show opens it on that only while not.
  var isShown: Bool { get }
  /// Shows the hidden panel without listening, on what `arriving` commits: it runs once a kept conversation
  /// that ran out has ended and before anything is drawn, so the screen left behind never shows first.
  func show(arriving: @escaping () -> Void)
  func perform(_ effect: PaletteEffect)
}
enum PaletteChange: Equatable {
  /// What the screens show: the panel renders the page and sizes itself at once.
  case content
  /// What the screens show, with the page shown now at the height measured for its turn before it showed.
  case measured(PageHeight)
  /// Only what is selected: the page paints it at once, and beside a list the selected item's detail
  /// shows, without waiting for the next render.
  case selection
}
/// A page's height, measured for its turn.
struct PageHeight: Equatable {
  let turn: String
  let height: Double
}
/// What measuring a page before it shows found (`PaletteSurface.prepare`).
enum PageMeasurement: Equatable {
  case measured(PageHeight)
  /// The renderer moved on to another page before it measured this one (one renderer serves every
  /// page): measure again.
  case superseded
  /// Nothing measured it: rendering failed, or the panel is hidden. It shows at once, at the height the
  /// renderer has, and is measured where it shows.
  case unmeasured
}
/// What leaves the screens.
enum PaletteEffect: Equatable {
  /// What Return, a button or a menu item chose that is not the screens': a copy, paste, open or reveal,
  /// or recording a hotkey (`Navigator.activate`), and the row it came from.
  case run(RowAction, from: Result?)
  /// A hidden run starts (`Navigator.runHidden`): the panel hides, as the user hiding it would.
  case hide
  /// The Settings destination: the launcher leaves for the native window.
  case settings
}

/// What the panel shows, as the navigator committed it in one step: the card's content and selection,
/// what its height depends on, and the placeholder and footer hints that go with them. The view draws it
/// and the native frame is sized from it (`PaletteLayout.cardHeight`), so both take the same values in
/// the same turn. What is typed into the input and the slots is the fields' own, read as it is.
struct PalettePresentation: Equatable {
  var compactRoot = false
  var footerProblem: String?
  var voiceStatus: String?
  var showsCard: Bool {
    !compactRoot || footerProblem != nil || voiceStatus != nil || page != nil || actionsTitle != nil
  }
  /// What the arrow keys walk: the action panel's rows, the page's targets, else the list.
  var rows: [Result] = []
  var selection: String?
  /// What Return runs, from the row it belongs to (`Navigator.selected`).
  var selected: Result?
  /// The rows the list card is sized for (`Navigator.sizedRows`), and their height at the text size.
  var sizedRows = 1
  var rowHeight = Configuration.TextSize.medium.rowHeight
  var prominentFirst = false
  /// A command's list with the selected item's detail beside it (`preview`).
  var splits = false
  var preview: Preview?
  var nearbyPictures: [URL] = []
  struct Preview: Equatable {
    let page: Page
    let turn: String
  }
  /// The row whose actions the action panel lists; nil while it is closed.
  var actionsTitle: String?
  /// The agent's screen, nil while another one shows.
  var agent: AgentPresentation?
  var headerHeight: CGFloat = 32
  var confirmationHeight: CGFloat = 210
  var permissionPending = false
  /// The open command: its id, name, failure, whether it is running and has for long enough to say so
  /// (`Navigator.showsBusy`), and its view's own actions.
  var command: String?
  var commandName: String?
  var problem: String?
  var busy = false
  var showsBusy = false
  var viewActions: [RowAction] = []
  var viewRow: Result?
  /// The page shown, its turn and its selected target.
  var page: Page?
  var pageTurn = ""
  var inDetail = false
  var selectedTarget: String?
  var offersActions = false
  var returnsOnEscape = false
  var askingAbout: String?
  var askingName = ""
  /// A pattern that matched what is typed is still running at the root (`Navigator.awaitsPattern`).
  var awaitsPattern = false
  /// Return does nothing on the selected row (`Navigator.returnPlan`), so the footer offers only ⌘↩.
  var refusesReturn = false
}

extension Navigator {
  /// The screens as the panel draws them now.
  var presentation: PalettePresentation {
    PalettePresentation(
      compactRoot: compactRoot, footerProblem: footerProblem(), voiceStatus: speech?.status,
      rows: results, selection: selection, selected: selected, sizedRows: sizedRows,
      rowHeight: configuration.textSize.rowHeight, prominentFirst: prominentFirst, splits: splits,
      preview: preview.map { PalettePresentation.Preview(page: $0.page, turn: $0.turn) },
      nearbyPictures: nearbyPictures, actionsTitle: actionsTitle, agent: agentScreen,
      headerHeight: conversationHeaderHeight, confirmationHeight: confirmationHeight,
      permissionPending: permissionPending, command: command?.id, commandName: commandName,
      problem: command?.problem, busy: command?.busy == true, showsBusy: showsBusy, viewActions: viewActions,
      viewRow: viewRow,
      page: page, pageTurn: pageTurn, inDetail: inDetail, selectedTarget: selectedTarget,
      offersActions: offersActions, returnsOnEscape: returnsOnEscape, askingAbout: askingAbout,
      askingName: askingName, awaitsPattern: awaitsPattern, refusesReturn: returnPlan() == .refuse)
  }
}
