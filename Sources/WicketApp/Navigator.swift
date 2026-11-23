import AppKit
import Observation

/// The launcher's screens and how the user moves between them. The root's search is always at the bottom,
/// an open command over it, and the agent's screen over either (`AgentScreen`); details and the action
/// panel are layers over the screen shown. It switches screens once the next one has its content
/// (`arrive`), stages the open command's requests and hands each visit what they were answered with
/// (what a request takes and answers is the command's behavior, `CommandScreenBehavior`), routes the
/// selection the keys move and decides what Return, Escape and the arrows do. It reaches
/// the panel only through `PaletteSurface`: drawing, measuring a page, and effects on the system, which
/// are the panel's, as are dictation (`PanelInput`) and recording a hotkey. Applying a configuration is
/// the services' (`LauncherModel`), and the agent's process, turns and permissions are `AgentSession`'s.
@MainActor @Observable
final class Navigator {
  let agent: AgentSession
  private let directory: CommandDirectory
  private let search: RootCommand
  private let store: ConfigurationStore
  private let history: UsageHistory
  /// Whether dictation is writing the input: a request made meanwhile waits for the transcript to settle,
  /// and what runs or prefills the input stops it first (`PanelInput`).
  @ObservationIgnored weak var speech: (any Speech)?
  /// The launcher's footer message, supplied by the model that owns its sources.
  @ObservationIgnored var footerProblem: () -> String? = { nil }
  var configuration: Configuration { store.configuration }
  var extensions: ExtensionHost { directory.extensions }

  init(
    agent: AgentSession, directory: CommandDirectory, root: RootCommand, store: ConfigurationStore,
    history: UsageHistory
  ) {
    self.agent = agent
    self.directory = directory
    search = root
    self.store = store
    self.history = history
    agent.onChange = { [weak self] in self?.agentChanged() }
    directory.extensions.onCatalogChange = { [weak self] in self?.sourcesChanged($0) }
  }

  // MARK: The screens

  /// The root's screen. The command's is in `command`, the agent's in `conversation`.
  private var base = Screen(draftFollowsSelection: true)
  private(set) var command: CommandScreen? {
    didSet { if command?.id != oldValue?.id { command?.screen.startSelectionOver() } }
  }
  /// The agent's screen, open while its session is: the navigator opens both together and ends both
  /// together (`closeConversation`), quitting included (`finish`).
  private var conversation: AgentScreen?
  private var conversing: Bool { conversation != nil }
  /// The screen shown: the agent's, the open command's, or the root's.
  private var screen: Screen {
    get { conversation?.screen ?? command?.screen ?? base }
    set {
      if conversing {
        conversation?.screen = newValue
      } else if command != nil {
        command?.screen = newValue
      } else {
        base = newValue
      }
    }
  }
  /// What is typed on the screen shown.
  var input: String {
    get { conversing ? screen.input : command?.input ?? base.input }
    set {
      let previous = input
      let changed = newValue != previous
      if !conversing, command != nil { command?.input = newValue } else { screen.input = newValue }
      if changed {
        if command == nil, !conversing { revealedRootList = false }
        resetSelection()
        // Typing in a conversation goes back to the follow-up: Return no longer runs an item.
        if conversing { clearSelection() }
      }
      if !conversing, arriving == nil {
        if agentOwnsCommandInput { return publish() }
        refresh(typed: changed)
        // The card can change as soon as the input changes, before the new rows arrive.
        if configuration.compactOnOpen, newValue.isEmpty != previous.isEmpty, search.isSearching { draw() }
      }
    }
  }
  /// The session changed: a turn's text or status, or a permission, which needs to be seen while its
  /// screen shows. A session the navigator is ending or replacing (a reset on the way to another agent)
  /// is not: what shows next is drawn once it is there.
  private func agentChanged() {
    guard conversing, agent.active else { return }
    if !agent.permissions.isEmpty { closeActions() }
    draw()
  }
  /// Ends the agent's screen, then its session. The caller draws the screen under it.
  private func closeConversation() {
    conversation = nil
    agent.reset()
  }

  /// The list at search and inside a command.
  private var listed: [Result] {
    get { command?.screen.rows ?? base.rows }
    set {
      if command != nil { command?.screen.rows = newValue } else { base.rows = newValue }
      sizeList()
    }
  }
  /// The rows the list card is sized for: more show at once, fewer only after 300 ms, so a late batch
  /// such as file results does not make the panel shrink and grow again while typing. The pause counts
  /// from the first shorter list and is not restarted by later ones; once no source is pending the list
  /// is final and sized at once. A list for another screen is sized at once too: the hold is for
  /// results of one screen arriving late.
  private(set) var sizedRows = 1
  @ObservationIgnored private var shrinking: Task<Void, Never>?
  @ObservationIgnored private var sizedFor: String?
  private func sizeList(now: Bool = false) {
    let count = max(1, min(results.count, 8))
    let shown = command?.id
    let settled = search.pending.isEmpty && command?.busy != true
    guard count < sizedRows, !now, !settled, shown == sizedFor else {
      shrinking?.cancel()
      shrinking = nil
      sizedFor = shown
      sizedRows = count
      return
    }
    guard shrinking == nil else { return }
    shrinking = Task { [weak self] in
      guard (try? await Task.sleep(for: .milliseconds(300))) != nil, let self else { return }
      shrinking = nil
      sizedRows = max(1, min(results.count, 8))
      draw()
    }
  }
  /// What the arrow keys walk: the action panel's rows, the open page's targets in reading order, else
  /// the list.
  var results: [Result] {
    if let overlay { return overlay.rows }
    guard let page else { return conversing ? [] : listed }
    let provider = conversing ? "answer" : command?.id ?? ""
    return page.targets.map { Result(provider: provider, row: $0) }
  }
  /// The page shown: an open detail, the conversation's answer, or the open command's body.
  var page: Page? {
    if let detail = openDetails.last { return detail.page }
    if conversing { return agent.question.isEmpty ? nil : agent.page }
    return command?.problem == nil ? command?.page : nil
  }
  /// Which page is shown, for the renderer (a new one starts at its top) and for clicks, which count
  /// only on the page they were made on.
  var pageTurn: String { openDetails.last?.turn ?? baseTurn }
  /// A command's list whose items carry a `detail` shows the selected one's beside it (`preview`). Not at
  /// the root, in a conversation, on a page or under the action panel. Keep split previews out of root
  /// search so ordinary keystrokes never have to render WebKit content.
  var splits: Bool {
    !conversing && command != nil && page == nil && overlay == nil
      && listed.contains { $0.row.detail != nil }
  }
  /// The selected item's detail, written with the view, so an arrow key shows it with no request; empty
  /// for an item without one. Its turn names the command, so the pane shows no other screen's page.
  var preview: (page: Page, turn: String)? {
    guard splits, let command else { return nil }
    let row = selectedRow?.row
    return (
      Page(body: row?.detail ?? "", runs: true, picture: row?.picture, copies: false),
      Self.previewTurn(command.id, row?.id)
    )
  }
  /// The pictures of the items beside the selected one, which the canvas prepares ahead of an arrow key.
  var nearbyPictures: [URL] {
    guard splits, let index = listed.firstIndex(where: { $0.id == selection }) else { return [] }
    return [index + 1, index - 1].compactMap { listed.indices.contains($0) ? listed[$0].row.picture : nil }
  }
  static func previewTurn(_ command: String, _ item: String?) -> String {
    "detail:\(command):" + (item ?? "")
  }
  var prominentFirst: Bool { results.first.map { $0.row.prominent == true } ?? false }
  var conversationHeaderHeight: CGFloat = 32 {
    didSet { if conversationHeaderHeight != oldValue { draw() } }
  }
  var confirmationHeight: CGFloat = 210 {
    didSet { if confirmationHeight != oldValue { draw() } }
  }
  /// What the last action could not do, until the next action, the user's next input or the configuration
  /// changing. Over a conversation it is the footer's line (`AgentPresentation.footer`), so it is drawn.
  var actionProblem: String? {
    didSet {
      if actionProblem != oldValue, conversing || (actionProblem != nil && compactRoot) {
        draw()
      }
    }
  }

  /// Down reveals the empty root for this visit. Typing or hiding starts it over.
  private var revealedRootList = false
  private var rootHasProblems = false
  var compactRoot: Bool {
    configuration.compactOnOpen && command == nil && !conversing && input.isEmpty && !revealedRootList
      && !(composedInput == input && rootHasProblems)
  }

  /// The panel the screens show in (`PaletteSurface`).
  @ObservationIgnored weak var surface: (any PaletteSurface)?
  /// `measured`: the page shown now was measured before it showed, at this height.
  private func draw(_ measured: PageHeight? = nil) {
    surface?.present(measured.map { .measured($0) } ?? .content, presentation)
  }

  // MARK: Layers: details and the action panel

  private var baseTurn: String { conversing ? agent.turnID : command?.turn ?? "" }
  /// The details open over the page shown; those of an earlier page are not.
  private var openDetails: [Detail] { screen.details(over: baseTurn) }
  var inDetail: Bool { !openDetails.isEmpty }
  /// The selected target's id as the page knows it.
  var selectedTarget: String? {
    page == nil || overlay != nil ? nil : results.first { $0.id == selection }?.row.id
  }
  /// Opens an item's content as its own page, with no model call and no extension run, and the item's
  /// own action as a row at its end. Its items may run the open command as the page it came from could.
  func openDetail(_ markdown: String, action: Row?, from result: Result?) {
    screen.open(
      Detail(
        page: Page(body: markdown, items: action.map { [$0] } ?? [], runs: !conversing), base: baseTurn,
        turn: pageTurn + ">" + (result?.row.id ?? "")))
    draw()
  }
  private var overlay: ActionPresentation?
  /// The title of the row whose actions the panel lists; nil while it is closed.
  var actionsTitle: String? { overlay?.source.row.title }
  /// What can be done with a row: its own actions, then the host's (Set Hotkey…, and Remove Hotkey when
  /// one is set). The context menu and the action panel list exactly these.
  func actions(of result: Result) -> [RowAction] {
    guard let target = hotkeyTarget(of: result) else { return result.row.actions }
    let bound = configuration.hotkeys.contains { $0.target == target }
    return result.row.actions + [RowAction(.hotkey(target, record: true))]
      + (bound ? [RowAction(.hotkey(target, record: false))] : [])
  }
  /// The row ⌘K is about: the selected one, or on a page with nothing selected the view itself.
  private var actionSource: Result? { selectedRow ?? viewRow }
  private var selectedRow: Result? { results.first { $0.id == selection } }
  /// The open command's page as a row: its title and the view's own actions. Nil in a detail.
  var viewRow: Result? {
    guard !conversing, let command, body != nil, !inDetail else { return nil }
    return Result(
      provider: command.id, row: Row(id: "detail", title: commandName ?? "Details", actions: viewActions))
  }
  /// Whether ⌘K has more to offer than Return, for the footer.
  var offersActions: Bool { overlay == nil && actionSource.map { actions(of: $0).count > 1 } == true }
  /// ⌘K: lists the actions of `source`, else of the selected row or the view, as single-action rows, so
  /// arrows, Return and clicks work as in any list. Again, it returns to where the user was.
  func toggleActions(_ source: Result? = nil) {
    if overlay != nil { return closeActions() }
    guard arriving == nil, agent.permissions.isEmpty, let source = source ?? actionSource else { return }
    let rows = actions(of: source).enumerated().map { index, action in
      Result(
        provider: "actions",
        row: Row(id: String(index), title: action.label, icon: action.symbol, actions: [action]))
    }
    guard let first = rows.first else { return }
    overlay = ActionPresentation(source: source, rows: rows)
    focusTarget = nil
    select(first.id)
    sizeList(now: true)
    draw()
  }
  /// Back to the screen ⌘K was pressed on, with its selection as it was.
  private func closeActions() {
    guard overlay != nil else { return }
    overlay = nil
    reconcileSelection()
    sizeList(now: true)
    draw()
  }
  /// What Return or a menu item runs, and the row it came from. An action chosen in the action panel
  /// closes it and belongs to the row the panel was opened for.
  func pick(_ chosen: RowAction? = nil) -> (action: RowAction, from: Result?)? {
    guard let action = chosen ?? returnAction else { return nil }
    guard let overlay else { return (action, selected) }
    closeActions()
    return (action, overlay.source)
  }

  // MARK: Selection

  /// The selection the arrow keys move: the action panel's, the open detail's, else the screen's.
  private var current: Selection {
    get { overlay?.selection ?? screen.selection(over: baseTurn) }
    set {
      let old = current.id
      if overlay != nil {
        overlay?.selection = newValue
      } else {
        screen.select(newValue, over: baseTurn)
      }
      guard newValue.id != old else { return }
      // The draft is gone, so the input takes the keys again.
      if command == nil { focusTarget = nil }
      surface?.present(.selection, presentation)
    }
  }
  var selection: String? { current.id }
  func select(_ id: String?) {
    returnQueued = false
    let repicked = id == current.id && !current.picked
    current.pick(id)
    // Same row, so the setter draws nothing, but Return may now act on it: the footer shows its hint.
    if repicked { surface?.present(.selection, presentation) }
  }
  private func clearSelection() {
    current.touched = false
    current.id = nil
  }
  private func resetSelection() { screen.startSelectionOver(over: baseTurn) }
  /// The one step after a screen's content changed: the selection follows it, then the panel draws it.
  private func publish(_ measured: PageHeight? = nil) {
    retainSelection()
    draw(measured)
  }
  private func retainSelection() {
    guard overlay == nil else { return }
    var selection = current
    selection.follow(
      results.map(\.id), waits: itemsWait, onPage: page != nil, pending: !search.pending.isEmpty)
    current = selection
  }
  /// Back on a screen or page as the user left it: its own selection, kept unless its rows changed meanwhile.
  private func reconcileSelection() {
    current.reset = false
    retainSelection()
  }
  /// Whether the input has the first say, so items wait for an arrow key and typing leaves them: in a
  /// conversation Return sends the follow-up, in a submit command it sends the request, and on a page
  /// it runs the view's actions. Wicket's permission gate for what is typed and filled in now is the
  /// exception: sending that request again would only show the gate again, so Return allows.
  private var itemsWait: Bool {
    overlay == nil && (conversing || agentOwnsCommandInput || submits || page != nil) && !gateIsCurrent
  }
  /// After an edit Return sends the edited request instead, so a grant then follows that one.
  private var gateIsCurrent: Bool {
    guard let command, !conversing, Permissions.isGate(results) else { return false }
    guard case .grant(_, let rerun)? = results.first?.row.actions.first?.kind else { return true }
    let request = command.request()
    return rerun.input == request.input && (rerun.fields ?? [:]) == request.fields
  }
  /// Arrow keys: the first press enters the items under the input, and up from the first leaves them.
  func move(_ delta: Int) {
    defer {
      if delta > 0, overlay == nil, !inDetail, compactRoot {
        revealedRootList = true
        draw()
      }
    }
    let rows = results
    guard !rows.isEmpty else { return }
    guard let current = rows.firstIndex(where: { $0.id == selection }) else {
      select(rows[0].id)
      return
    }
    if current == 0, delta < 0, itemsWait {
      select(nil)
      return
    }
    select(rows[min(max(current + delta, 0), rows.count - 1)].id)
  }
  /// A click on a row: selects it, or on the selected command row with a filled draft, enters it like
  /// Return. True when the caller should run Return.
  func click(_ id: String) -> Bool {
    if command == nil, id == selection, !drafted.isEmpty { return true }
    select(id)
    return false
  }
  /// A click on a page's target selects it and runs it. It counts only on the page it was made on, so a
  /// click that raced a new answer or view is ignored. True when the caller should run Return.
  func clickTarget(_ id: String, turn: String) -> Bool {
    guard page != nil, overlay == nil, turn == pageTurn,
      let target = results.first(where: { $0.row.id == id })
    else {
      return false
    }
    select(target.id)
    return true
  }

  // MARK: Return, fields and the input

  /// The open command's Markdown body.
  var body: String? { command?.body }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { command?.viewActions ?? [] }
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? { command?.descriptor?.name }
  private var agentOwnsCommandInput: Bool {
    command != nil && !conversing && command?.descriptor?.inputField == nil
  }
  var commandPlaceholder: String? {
    guard let name = commandName else { return nil }
    return command?.descriptor?.inputField.map { $0.placeholder ?? name } ?? "Ask about \(name)…"
  }
  var returnAsksAgent: Bool {
    agentOwnsCommandInput && overlay == nil && selectedRow?.row.actions.first == nil
  }
  /// The open command runs on Return only (`CommandDescriptor.submits`).
  var submits: Bool { command?.descriptor?.submits == true }
  /// Return runs the selected item. With none selected, a submit command sends what is typed and
  /// filled in as a submitted request, a page runs the view's own actions, and a conversation sends the
  /// follow-up.
  var selected: Result? {
    if let row = selectedRow { return row }
    if returnAsksAgent || !conversing && command?.runningAction == true { return nil }
    guard !conversing, let submission = command?.submission() else { return viewRow }
    return submission
  }
  /// What Return does: the selected row's first action, or in a conversation with nothing selected,
  /// sending the follow-up. On a command row it enters the command with what was filled into its
  /// declared fields.
  var returnAction: RowAction? {
    if arriving?.command?.runningAction == true { return nil }
    if returnAsksAgent { return RowAction(.ask) }
    guard var action = selected?.row.actions.first else { return conversing ? .send(input) : nil }
    if command == nil, !drafted.isEmpty, case .run(var address) = action.kind {
      address.fields = drafted
      action.kind = .run(address)
    }
    return action
  }
  /// The fields the user can fill in: inside a command its own declared ones, at the root those of
  /// the selected extension command row. Empty when there are none.
  var fieldSlots: [ExtensionManifest.Field] {
    guard !conversing, overlay == nil else { return [] }
    if let command {
      guard let descriptor = command.descriptor else { return [] }
      let main = descriptor.inputField?.name
      return descriptor.fields.filter { $0.inSearchBar && $0.name != main }
    }
    guard let row = results.first(where: { $0.id == selection }), row.row.id == "command" else { return [] }
    return directory.behavior(of: row.provider)?.descriptor?.fields.filter(\.inSearchBar) ?? []
  }
  /// Values filled in at the root for the selected command row; dropped when the selection moves or
  /// the panel is dismissed. Only the row itself takes them: an action chosen in ⌘K runs as captured.
  private var drafted: [String: String] {
    command == nil && !conversing && overlay == nil ? base.fields : [:]
  }
  /// The current values by name: the open command's fields, or the root draft. Unfilled is absent.
  var fieldValues: [String: String] {
    if let command, !conversing { return command.request().fields }
    return screen.fields
  }
  /// Fills in a declared field. Inside a command it is an edit like typing: it reruns the command,
  /// or in a submit command waits for Return.
  func setField(_ name: String, to value: String) {
    guard fieldSlots.contains(where: { $0.name == name }) else { return }
    guard command != nil else {
      base.fill(name, with: value)
      return pickFieldRow()
    }
    command?.screen.fill(name, with: value)
    resetSelection()
    refresh()
  }
  /// The field slot that has the keyboard, by name; nil is the input. Only a declared name counts, so
  /// the input takes the keys back when the slots go away. A click into a field sets it too.
  var focusedField: String? {
    get { focusTarget.flatMap { name in fieldSlots.contains { $0.name == name } ? name : nil } }
    set {
      focusTarget = newValue
      if focusedField != nil { pickFieldRow() }
    }
  }
  private var focusTarget: String?
  /// Focusing or filling a slot at the root picks the command row it belongs to (`returnPlan` rule 2):
  /// a pattern arriving no longer takes the selection and the draft with it, and a Return waiting from
  /// before is called off.
  private func pickFieldRow() {
    if command == nil, let selection { select(selection) }
  }
  /// Tab and Shift+Tab: the input, then each slot in order, round again. False when there are none.
  @discardableResult func moveFocus(_ delta: Int) -> Bool {
    let names = [nil] + fieldSlots.map(\.name)
    guard names.count > 1 else { return false }
    let index = names.firstIndex(of: focusedField) ?? 0
    focusTarget = names[(index + delta + names.count) % names.count]
    if focusTarget != nil { pickFieldRow() }
    return true
  }
  /// Used by the native field, including paste and IME edits that arrive without a shortcut.
  func editInput(_ edit: InputEdit) {
    actionProblem = nil
    // Typing in the action panel's empty field closes it, and what the field shows is the input: never
    // joined to the earlier input, which would rewrite the field under an input method's marked text.
    closeActions()
    // Typing while a command is being entered goes to it: the switch happens now, and what the edit
    // inserted into the input being left, wherever the caret was, is what is typed into the new one.
    if let arrival = arriving {
      let old = input
      let left = conversing
      showArrival()
      input = edit.base == old ? arrival.input + edit.inserted : edit.text
      if left { draw() }
      return
    }
    input = edit.text
  }
  /// An edit that leaves `text` in the field, as typed at its end.
  func editInput(_ text: String) { editInput(InputEdit(text, from: input)) }
  /// A transcript: like typing, speech during a screen switch switches at once, and it is the whole input.
  func dictate(_ text: String) {
    actionProblem = nil
    let left = arriving != nil && conversing
    showArrival()
    input = text
    if left { draw() }
  }
  /// The input the root's rows were composed for. Until the rows of an edit are there (normally after
  /// `RootCommand.patternHold`), the previous ones still show.
  private var composedInput = ""
  /// What Return does with the selected row, the one place that decides it. At the root:
  ///
  /// 1. It waits for the rows composed for what is typed, so it never runs a row made for an earlier input.
  /// 2. A row the user picked runs at once; focusing or filling a command row's field picks it. The
  ///    row that takes the place of a picked one that went away (its own pattern answered) is not picked.
  /// 3. A pattern's result on screen when Return is pressed runs at once: the user sees what it runs.
  /// 4. Otherwise it waits while a pattern still running would list its rows above the selected row
  ///    (`RootCommand.outranked`): what is typed was meant for it.
  /// 5. After a pattern that matched failed, Return is refused (nothing runs, nothing waits) on Ask agent
  ///    standing in for it, and, in a replay, on anything but a pattern's result: what is typed was meant
  ///    for the pattern, not for the file or row that took its place unseen. A fresh press on that row
  ///    runs it; ⌘↩, or picking Ask agent or the error row, still acts.
  /// 6. Else the selected row runs.
  ///
  /// Anywhere else (a command, a conversation, a switch, the action panel) it runs at once. A Return
  /// that waits is decided again on each list composed, as a `replay`: rules 3 and 5 tell it from a press,
  /// since nobody saw the row it would run. It runs or is dropped once it no longer waits; an edit, a
  /// pick, a switch or hiding call it off. ⌘↩ never waits: it asks the agent with what is typed.
  enum ReturnPlan { case run, wait, refuse }
  func returnPlan(replay: Bool = false) -> ReturnPlan {
    guard command == nil, !conversing, arriving == nil, overlay == nil else { return .run }
    if composedInput != input { return .wait }
    if current.picked || !replay && search.isPatternResult(selected) { return .run }
    if search.outranked(selected) { return .wait }
    guard search.failedPattern else { return .run }
    let standIn = replay ? !search.isPatternResult(selected) : selected?.provider == "agent"
    return standIn ? .refuse : .run
  }
  /// A pattern that matched what is typed is still running at the root, so the list has no Ask agent yet
  /// and an empty list is not "No results".
  var awaitsPattern: Bool { command == nil && !conversing && !search.runningPatterns.isEmpty }
  /// A Return that waits (`returnPlan`).
  private(set) var returnQueued = false
  /// Return, a button or a menu item: the action chosen, else what Return does (`returnPlan`), from the
  /// row it belongs to. What is not the screens' goes to the panel.
  func run(_ chosen: RowAction? = nil) {
    // What runs takes the input from dictation first, so a later transcript cannot rewrite it.
    speech?.stop(.run)
    if chosen == nil {
      let plan = returnPlan()
      returnQueued = plan == .wait
      guard plan == .run else { return }
    }
    guard let (action, result) = pick(chosen), !activate(action, from: result) else { return }
    surface?.perform(.run(action, from: result))
  }

  // MARK: Switching screens

  /// The screen being switched to while its first content is on its way: a command (nil for the root)
  /// and its input. Until it arrives, or `arrivalDeadline` passes, the screen being left stays exactly as
  /// it was, so the panel's content and height change together in one step (`arrive`). Collapsing at once
  /// and growing on arrival was tried and rejected: a command with many items flashed small, then large.
  @MainActor private struct Arrival {
    var command: CommandScreen?
    private let rootInput: String
    var input: String { command?.input ?? rootInput }
    /// Going back (Escape): a second Escape waits for it instead of calling it off.
    var back = false

    init(command: CommandScreen?, input: String, back: Bool = false) {
      self.command = command
      self.command?.input = input
      rootInput = input
      self.back = back
    }
  }
  private var arriving: Arrival?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  var arrivalDeadline: Duration = .milliseconds(150)
  /// The command requests go to: the arriving one during a switch, else the open one.
  private var target: CommandScreen? {
    get { arriving.map(\.command) ?? command }
    set {
      if arriving != nil { arriving?.command = newValue } else { command = newValue }
    }
  }
  /// The open command's running request.
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  /// The busy state (Running…, the spinner) shows only once a request's process has run this long, so a
  /// quick answer replaces the screen without it flashing first, whether Return, a link or a hotkey asked.
  /// Neither the wait for dictation to settle nor measuring the answer's page counts.
  var busyDelay: Duration = .milliseconds(400)
  @ObservationIgnored private var busyTimer: Task<Void, Never>?
  @ObservationIgnored private var ranLong = false
  /// The open command's request has run for `busyDelay`.
  var showsBusy: Bool { ranLong && command?.busy == true }
  @ObservationIgnored private var generation = 0
  /// Ends what the screen shown is waiting for: its request, the root's search and a waiting Return.
  func cancelWork() {
    returnQueued = false
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    busyTimer?.cancel()
    ranLong = false
    search.cancel()
    command?.stop()
  }
  /// Stays on the current screen: a switch still waiting for its content is called off.
  private func stopArriving() {
    arriving = nil
    deadline?.cancel()
    deadline = nil
  }
  /// Switches to a screen once its first content is there: a command's first view, or the root's
  /// built-in results. The current screen stays as it is meanwhile; after `arrivalDeadline` the new one
  /// shows anyway, quietly loading, so a slow process does not make Return feel dead. A command
  /// answered without a process switches at once. Ending a conversation waits the same way. Not
  /// `holding`, it shows at once: the panel just showed, and there is no screen worth keeping.
  private func arrive(_ command: CommandScreen?, input: String, back: Bool = false, holding: Bool = true) {
    stopArriving()
    cancelWork()
    arriving = Arrival(command: command, input: input, back: back)
    refresh()
    guard arriving != nil else { return }
    guard holding else { return passDeadline() }
    deadline = Task { [weak self] in
      guard let self, (try? await Task.sleep(for: arrivalDeadline)) != nil else { return }
      passDeadline()
    }
  }
  /// The arrival's deadline: the screen being switched to shows now, quietly loading if its content is
  /// not there yet. Tests pass it themselves to order it against the content and the page's measurement.
  func passDeadline() {
    guard arriving != nil else { return }
    showArrival()
    publish()
  }
  /// Makes the arriving screen the visible one. The caller publishes its content in the same turn. Leaving
  /// the agent's screen this way, not by Escape from an empty question, finds the screen under it started
  /// over: its selection from the first row, its input the arrival's, and the root's draft gone.
  private func showArrival() {
    guard let arrival = arriving else { return }
    overlay = nil
    let conversed = conversing
    if conversed {
      closeConversation()
      base.fill([:])
    }
    let entering = arrival.command?.id != command?.id
    if entering, command == nil { base.fill([:]) }
    command = arrival.command
    if entering || conversed { screen.startSelectionOver() }
    input = arrival.input  // No refresh while arriving: its request is already answered or running.
    stopArriving()
    if entering { listed = [] }
  }
  /// What sources answer changed without the user: the installed apps, the extension catalog or which
  /// sources are on. The root composes again. An open command reruns only when `ids` names it (its
  /// manifest changed, it went away, or it was switched on or off), which also cancels its running
  /// request; anything else would replace what the user is looking at for no reason of its own.
  func sourcesChanged(_ ids: Set<String>) {
    if let id = target?.id, !ids.contains(id) { return }
    refresh()
  }
  /// A configuration was applied: the sources it switched on or off answer again, the last action's
  /// problem goes, and the panel draws the rest (text size, appearance). Nil when only its file was read.
  func applied(switching switched: Set<String>?) {
    if let switched {
      actionProblem = nil
      sourcesChanged(switched)
    }
    draw()
  }
  /// `typed`: the input was edited, which a command's context ignores unless an address set it.
  func refresh(typed: Bool = false) {
    guard !conversing || arriving != nil else { return }
    let input = arriving?.input ?? self.input
    if let state = target {
      let request = state.request()
      let work = state.behavior.work(for: request)
      guard case .keepView = work else { return answer(work, for: request, typed: typed) }
      showArrival()
      publish()
      return
    }
    cancelWork()
    search.search(input, speaking: speech?.speaking == true) { [weak self] in self?.show($0) }
  }
  /// Answers a command's request as `work` says: what fails or is answered at once shows now, and a
  /// process's answer once it is there, unless another request or visit replaced it meanwhile.
  private func answer(_ work: CommandWork, for request: CommandScreenRequest, typed: Bool) {
    let speaking = speech?.speaking == true
    cancelWork()
    target?.begin()
    // The user did not cause it by typing, so what it shows becomes its context.
    let remembered = !typed || request.cause != .rerun
    switch work {
    case .keepView: return
    case .unavailable(let problem):
      target?.unavailable(problem)
      showArrival()
      sizeList()
      return publish()
    case .immediate(let outcome):
      if accept(outcome, for: request, page: nil, turn: UUID().uuidString, remembered: remembered) {
        publish()
      }
      return
    case .deferred(let answered):
      target?.run(request)
      let version = generation
      let visit = target?.visit
      let turn = UUID().uuidString
      tasks.append(
        Task { [weak self] in
          if speaking, (try? await Task.sleep(for: .milliseconds(350))) == nil { return }
          self?.timeBusy(version)
          let outcome = await answered()
          guard let self else { return }
          // A newer request cancelled this one's timer and may have started its own.
          if generation == version { busyTimer?.cancel() }
          // Only the visit and the run that asked take what it was answered with.
          @MainActor func current() -> Bool {
            !Task.isCancelled && generation == version && target?.visit == visit
          }
          guard current() else { return }
          var page: Page?
          var measured: PageHeight?
          if case .view(let view) = outcome, let body = view.body {
            page = Page(body: body, items: view.items, runs: true)
          }
          // Measured for this page's turn: one the renderer measured meanwhile, such as a list's detail
          // on an arrow key, says nothing about this one's height. What failed shows unmeasured at once.
          while arriving != nil, let page, let surface {
            let measurement = await surface.prepare(page, turn: turn)
            guard current() else { return }
            if measurement == .superseded { continue }
            if case .measured(let height) = measurement, height.turn == turn { measured = height }
            break
          }
          if accept(outcome, for: request, page: page, turn: turn, remembered: remembered) {
            publish(measured)
          }
        })
      draw()
    }
  }
  /// Starts timing request `version`'s process for `busyDelay`, which a newer request cancels.
  private func timeBusy(_ version: Int) {
    let delay = busyDelay
    busyTimer = Task { [weak self] in
      // Cancelled once the process answered, even if its sleep had just ended.
      guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled, let self, generation == version
      else { return }
      ranLong = true
      if showsBusy { draw() }
    }
  }
  /// Takes what a request was answered with: a view or a problem shows on the command, which arrives if
  /// it was on its way, and a run to restore opens its conversation. False when the screens are left as
  /// they were.
  private func accept(
    _ outcome: CommandOutcome, for request: CommandScreenRequest, page: Page?, turn: String,
    remembered: Bool
  ) -> Bool {
    switch outcome {
    case .view(let view):
      showArrival()
      command?.show(view, page: page, for: request, turn: turn, remembered: remembered)
    case .problem(let problem):
      showArrival()
      command?.fail(problem, remembered: remembered)
    case .restore(let run):
      restore(run)
      return false
    }
    sizeList()
    return true
  }
  /// Waits until no work is left, including work a refresh started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks + hiddenRuns.values { await task.value }
      await search.settled()
    } while seen != generation || !hiddenRuns.isEmpty
  }
  /// The root's list for what is typed; a Return that waits is decided again (`returnPlan`).
  private func show(_ output: RootCommand.Output) {
    showArrival()
    listed = output.results
    composedInput = output.input
    rootHasProblems = output.hasProblems
    publish()
    guard returnQueued else { return }
    switch returnPlan(replay: true) {
    case .wait: break
    case .refuse: returnQueued = false
    case .run:
      returnQueued = false
      run()
    }
  }
  /// Takes the user to an address. `origin` is the provider of the row it came from, which an address
  /// that omits its target names; any provider that is not a command means the root. An empty target
  /// is always the root. `submitted` marks the user activating a run action, which the first request says.
  /// `holding`: the screen being left stays until the new one has its content (`arrive`).
  func go(_ address: Address, from origin: String? = nil, submitted: Bool = false, holding: Bool = true) {
    let own = origin.flatMap { directory.isCommand($0) ? $0 : nil }
    let target = address.extensionName == nil ? own : address.targetID
    guard let destination = directory.destination(target) else {
      actionProblem = "No extension named \(target.map { Address(id: $0).extensionName ?? $0 } ?? "")"
      return
    }
    switch destination {
    case .settings: surface?.perform(.settings)
    case .agent: fill(address.input ?? input)
    case .root: arrive(nil, input: address.input ?? "", holding: holding)
    case .command(let behavior):
      let reopened = command?.id == behavior.id
      var state = command.flatMap { $0.id == behavior.id ? $0 : nil } ?? CommandScreen(behavior)
      state.enter(address, submitted: submitted)
      guard reopened, !conversing else { return arrive(state, input: state.input, holding: holding) }
      // The same screen: its request reruns in place.
      stopArriving()
      cancelWork()
      command = state
      if submitted, !address.link, address.action != nil {
        // A repeated Return must not pick the action again from the old view or its replacement.
        screen.select(Selection(touched: true, reset: false), over: baseTurn)
      } else {
        resetSelection()
      }
      refresh()
    }
  }
  /// An address from outside the panel: a hotkey's (`LauncherModel.press`), as Return on its item, or an
  /// external `wicket://` URL, which the user then runs with Return. A hidden panel shows at once on the
  /// address's screen, since it has no screen to hold; an open one follows it like a clicked link. Before
  /// the first extension scan (a URL that launched Wicket) it waits like `LauncherModel.press`, so the extension it names is known.
  /// Pressed again while the request it started still runs, a hotkey does nothing: the same binding, and
  /// no request replaced that one since (`generation`), such as one typing sent.
  func open(
    _ address: Address, from origin: String? = nil, submitted: Bool = false,
    pressed hotkey: HotkeyTarget? = nil
  ) {
    guard extensions.scanned else {
      Task { [weak self] in
        await self?.extensions.firstScan()
        self?.open(address, from: origin, submitted: submitted, pressed: hotkey)
      }
      return
    }
    let shown = surface?.isShown == true
    if shown, let hotkey, let pressed, pressed == (hotkey, generation), target?.busy == true { return }
    actionProblem = nil
    func arrive() {
      go(address, from: origin, submitted: submitted, holding: shown)
      pressed = hotkey.map { ($0, generation) }
    }
    if let surface, !shown { surface.show(arriving: arrive) } else { arrive() }
  }
  @ObservationIgnored private var pressed: (hotkey: HotkeyTarget, generation: Int)?
  /// A hotkey's copy, paste, open or reveal (`LauncherModel.press`), done as Return on its item would. The
  /// panel shows only to say why it could not, such as a paste without Accessibility access.
  func perform(_ action: RowAction) {
    if !activate(action) { surface?.perform(.run(action, from: nil)) }
    if actionProblem != nil, surface?.isShown == false { surface?.show { [self] in refresh() } }
  }
  /// What the user runs, whoever asked: Return, a button, a menu item or a link. Moving between screens,
  /// sending questions and removing a hotkey happen here; effects on the panel and the system (copy,
  /// paste, open, recording a hotkey) are the panel's, and this returns false for them, except an open or
  /// reveal that `OpenPolicy` refuses: that does nothing but say why. `result` is the row it came from.
  @discardableResult
  func activate(_ action: RowAction, from result: Result? = nil) -> Bool {
    actionProblem = nil
    switch action.kind {
    case .run(let address):
      if let result { record(result) }
      // Activating a run action is the user's choice; following a link never is.
      if address.hidden {
        runHidden(address, from: result?.provider)
      } else {
        go(address, from: result?.provider, submitted: !address.link)
      }
    case .send(let text): send(text)
    case .ask: askAgent()
    case .detail(let markdown, let action): openDetail(markdown, action: action, from: result)
    case .hotkey(let target, record: false): store.bind(nil, to: target)
    case .grant(let permission, let address): grant(permission, then: address)
    case .open, .reveal:
      guard let refusal = OpenPolicy.refusal(action) else { return false }
      actionProblem = refusal
    case .copy, .paste, .clip, .hotkey: return false
    }
    return true
  }
  /// Only picks that root search can learn from: not inside a chosen command, and not fallbacks.
  func record(_ result: Result) {
    guard command == nil, result.row.id != "fallback" else { return }
    history.record(result.id, input: input)
  }
  /// Hides the panel's screens: what was over them, a switch and the work of the screen shown end. A
  /// conversation stays with its follow-up for when the panel shows again; anything else leaves the root
  /// with an empty input.
  func dismiss() {
    overlay = nil
    revealedRootList = false
    screen.startSelectionOver()
    base.startSelectionOver()
    // The root's draft stays under an empty question that is kept, for Escape to find; it goes with the
    // question's expiry (`reopen`).
    if !returnsOnEscape { base.fill([:]) }
    focusTarget = nil
    agent.hidden()
    stopArriving()
    // Hiding stops a running command, also under a conversation.
    cancelWork()
    if conversing { return }
    command = nil
    input = ""
    sizeList(now: true)
  }
  /// The panel shows again. A conversation or empty question kept past its time is gone, and the root
  /// starts over.
  func reopen(now: Date) {
    guard agent.reopen(now: now) else { return }
    cancelWork()
    conversation = nil
    base.fill([:])
    base.startSelectionOver()
    command = nil
    input = ""
  }
  /// Quitting: the work of the screens stops, and the agent's screen ends before its session does.
  func finish() {
    cancelWork()
    guard conversing else { return }
    closeConversation()
    draw()
  }
  func escape() -> Bool {
    focusTarget = nil
    if overlay != nil {
      closeActions()
      return true
    }
    // Escape while a command is being entered stays where it was, and its request stops; a way back is
    // already on its way.
    if let arrival = arriving {
      if !arrival.back {
        stopArriving()
        cancelWork()
      }
      return true
    }
    // A detail goes back to where the user was on the page under it.
    if inDetail {
      screen.closeDetail(over: baseTurn)
      draw()
      return true
    }
    if returnsOnEscape {
      // Cmd+Return's empty question goes back to the screen under it as it was: nothing reruns.
      closeConversation()
      reconcileSelection()
      draw()
      return true
    }
    if conversing {
      // Ending the conversation goes back to what was open under it once that has its content.
      if agent.busy { agent.cancel() } else { arrive(command, input: "", back: true) }
      return true
    }
    if command != nil {
      arrive(nil, input: "", back: true)
      return true
    }
    if !input.isEmpty {
      input = ""
      return true
    }
    return false
  }

  // MARK: The agent's screen

  /// The agent's screen as drawn, nil while it is not open.
  var agentScreen: AgentPresentation? {
    conversation.map {
      AgentPresentation(agent, $0, actionProblem: actionProblem, covered: overlay != nil)
    }
  }
  /// A long question's header shows all of it, or two lines again.
  func toggleQuestion() {
    conversation?.expanded.toggle()
    draw()
  }
  /// The permission card has the keys: ⌘↩ allows, Escape denies, and Return does nothing.
  var permissionPending: Bool { conversing && !agent.permissions.isEmpty }
  /// Answers the permission the card asks about.
  func decide(_ allow: Bool) { agent.decide(allow) }
  /// Calls off the running turn.
  func cancelTurn() { agent.cancel() }
  /// Who Return asks: a draft goes to the agent configured now, since settings apply when it is sent.
  var askingName: String { agent.question.isEmpty ? configuration.agent.agent.title : agent.agentName }
  /// Goes to a conversation that `start` begins: what was over the screen, a switch on its way and the
  /// screen's work end, and the agent's screen opens with an empty input. Ending it refreshes the screen
  /// under it, and the root's draft is gone.
  private func converse(_ start: () -> Void) {
    overlay = nil
    stopArriving()
    cancelWork()
    base.fill([:])
    conversation = AgentScreen(back: .refresh)
    start()
    // A run with no turn to reopen leaves nothing to show.
    if !agent.active { conversation = nil }
    clearSelection()
    input = ""
  }
  func send(_ text: String? = nil) {
    let text = text ?? input
    guard !agent.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Only a new conversation asked from an extension's command learns what it showed.
    let context =
      conversing
      ? (agent.question.isEmpty ? revealContext : nil)
      : command?.agentContext(typed: !agentOwnsCommandInput)
    converse {
      agent.ask(
        text, context: context?.text, from: context?.name, settings: questionSettings(keeping: agent.reopened)
      )
    }
  }
  /// What a question goes with: the agent settings at the Text size. A run reopened from Agent History
  /// keeps its agent, with that agent's defaults when another one is configured now, read-only
  /// (`AgentOptions.readOnly`).
  private func questionSettings(keeping kept: AgentConfiguration.Agent?) -> AgentConfiguration {
    var settings = configuration.agent
    if let kept, kept != settings.agent {
      settings = AgentConfiguration()
      settings.agent = kept
      settings.mode = AgentOptions.readOnly[kept]
      settings.streamAnswers = configuration.agent.streamAnswers
    }
    settings.textSize = configuration.textSize
    return settings
  }
  private func restore(_ run: AgentHistory.Run) {
    let notice =
      run.agent == configuration.agent.agent
      ? nil : "Follow-ups are read-only. Choose \(run.agent.title) in Settings for your permission mode."
    converse { agent.restore(run, settings: questionSettings(keeping: run.agent), notice: notice) }
  }
  /// Cmd+Return: asks what is typed. With nothing typed it opens an empty question about what is on
  /// screen, which Escape leaves for exactly that screen again.
  func askAgent() {
    closeActions()
    guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return send() }
    guard !conversing else { return }
    // A switch still on its way is called off with its request, which would otherwise answer into the
    // screen under the question. That screen's own work already stopped when the switch began.
    if arriving != nil {
      stopArriving()
      cancelWork()
    }
    conversation = AgentScreen(back: .reveal(command?.agentContext(typed: false)))
    agent.open(settings: configuration.agent)
    clearSelection()
    input = ""
  }
  /// Escape leaves the empty question for the screen under it, as Cmd+Return found it.
  var returnsOnEscape: Bool {
    if case .reveal = conversation?.back { true } else { false }
  }
  /// What the empty question's first question tells the agent the screen under it showed.
  private var revealContext: AgentContext? {
    if case .reveal(let context) = conversation?.back { context } else { nil }
  }
  /// The extension whose view Cmd+Return would send with the question, for the footer and placeholder.
  var askingAbout: String? {
    if conversing { return agent.question.isEmpty ? revealContext?.name : nil }
    return command?.asksAbout(
      typed: !agentOwnsCommandInput && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  /// The `agent` action: the text becomes the input and nothing is sent. In a conversation the next
  /// Return is the follow-up. Anywhere else an open command is left and an empty conversation opens
  /// with the text as its unsent first question; ending it goes back to the root.
  func fill(_ text: String) {
    // The text is the input now: dictation, which would write over it, stops first.
    speech?.stop(.edit)
    if !conversing {
      converse {
        command = nil
        agent.open(settings: configuration.agent)
      }
    }
    editInput(text)
  }

  // MARK: Hotkeys

  /// What a row's hotkey is bound to (`CommandDirectory.hotkeyTarget`).
  func hotkeyTarget(of result: Result) -> HotkeyTarget? {
    directory.hotkeyTarget(of: result, atRoot: command == nil)
  }
  /// The hotkey a row shows at its trailing edge.
  func hotkey(of result: Result) -> Shortcut? {
    guard !configuration.hotkeys.isEmpty, let target = hotkeyTarget(of: result) else { return nil }
    return configuration.hotkeys.first { $0.target == target }?.keys
  }
  /// A hidden run (`Address.hidden`), from a row or a hotkey: the panel hides at once, then the program
  /// runs with a submitted request, on its own, so nothing the user does in the panel meanwhile stops it.
  /// A clean exit with nothing to show is the end. A failure or a view with a body or items shows on its
  /// command, as if Return had run it, without running again; while the panel is up, or over a
  /// conversation kept for when it shows, it is one line instead, so the screen the user is on stays. An
  /// address without an enabled program to run is followed as usual, which says why.
  func runHidden(_ address: Address, from origin: String?) {
    let own = origin.flatMap { directory.isCommand($0) ? $0 : nil }
    guard let id = address.extensionName == nil ? own : address.targetID,
      let program = extensions.commands[id], program.manifest.command != nil,
      let behavior = directory.behavior(of: id),
      directory.isAvailable(id, in: configuration)
    else { return open(address, from: origin, submitted: true) }
    var state = command.flatMap { $0.id == id ? $0 : nil } ?? CommandScreen(behavior)
    state.enter(address, submitted: true)
    let request = state.request().provider
    // A missing permission runs nothing and hides nothing: Wicket's row shows on the command, the panel
    // opening for it, since the user is waiting for an effect that will not come.
    let rerun = Address(
      id: id, input: request.input, fields: request.fields, action: request.action, hidden: true)
    if let gate = extensions.permissions.gate(program, rerun: rerun) {
      let present = { [self] in
        if conversing {
          actionProblem = "\(program.manifest.name): \(gate.items[0].title)"
        } else {
          adopt(program, request: request, outcome: .view(gate))
        }
      }
      if let surface, !surface.isShown { surface.show(arriving: present) } else { present() }
      return
    }
    // Only an open panel hides: hiding again would count as the user leaving a kept conversation now.
    if surface?.isShown == true { surface?.perform(.hide) }
    let run = UUID()
    hiddenRuns[run] = Task { [weak self, extensions] in
      var outcome: CommandOutcome?
      var line = ""
      do {
        let view = try await extensions.view(program, request: request)
        outcome = .view(view)
        line =
          view.items.first.map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: ": ") }
          ?? view.body.map { $0.prefix { $0 != "\n" }.trimmingCharacters(in: ["#", " "]) } ?? ""
      } catch let failure as ExtensionFailure where failure.nothingShown {
      } catch is CancellationError {
      } catch {
        outcome = .problem(program.report(request, error: error))
        line = String(error.localizedDescription.prefix { $0 != "\n" })
      }
      guard let self else { return }
      hiddenRuns[run] = nil
      guard let outcome else { return }
      let problem = "\(program.manifest.name): \(line)"
      guard surface?.isShown == false else {
        actionProblem = problem
        return
      }
      surface?.show { [self] in
        if conversing { actionProblem = problem } else { adopt(program, request: request, outcome: outcome) }
      }
    }
  }
  /// Asks macOS for a permission from Wicket itself (its prompt may hide the panel), then sends the
  /// request the gate held back again, as it was: a hidden run hidden, any other on its command.
  private func grant(_ permission: Permission, then address: Address) {
    let id = UUID()
    hiddenRuns[id] = Task { [weak self, extensions] in
      await extensions.permissions.request(permission)
      guard let self else { return }
      hiddenRuns[id] = nil
      if address.hidden { runHidden(address, from: nil) } else { open(address, submitted: !address.link) }
    }
  }
  /// Hidden runs and permission requests on their way, which `settled` waits for too.
  @ObservationIgnored private var hiddenRuns: [UUID: Task<Void, Never>] = [:]
  /// What a hidden run answered shows on its command as if Return had run it there, and nothing runs again.
  private func adopt(_ program: ExtensionCommand, request: ProviderRequest, outcome: CommandOutcome) {
    guard let behavior = directory.behavior(of: program.id) else { return }
    stopArriving()
    cancelWork()
    var state = CommandScreen(behavior)
    state.enter(Address(input: request.input, fields: request.fields), submitted: false)
    state.begin()
    // An arrival sets the input without a rerun.
    arriving = Arrival(command: state, input: state.input)
    var page: Page?
    if case .view(let view) = outcome, let body = view.body {
      page = Page(body: body, items: view.items, runs: true)
    }
    let shown = CommandScreenRequest(
      input: request.input, fields: request.fields, action: request.action, cause: .submission)
    if accept(outcome, for: shown, page: page, turn: UUID().uuidString, remembered: true) { publish() }
  }
}
