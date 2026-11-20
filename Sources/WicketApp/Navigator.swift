import AppKit
import Observation

/// The launcher's screens and how the user moves between them. The root's search is always at the bottom,
/// an open command over it, and the agent's screen over either (`AgentScreen`); details and the action
/// panel are layers over the screen shown. It switches screens once the next one has its content
/// (`arrive`), stages and delivers the open command's requests (what each takes is the directory's,
/// `CommandWork`), owns every selection and decides what Return, Escape and the arrows do. It reaches
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
  private var base = Screen()
  private(set) var command: CommandState? {
    didSet { if command?.id != oldValue?.id { command?.screen.selection.reset = true } }
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
    get { screen.input }
    set {
      let changed = newValue != screen.input
      screen.input = newValue
      if changed {
        resetSelection()
        // Typing in a conversation goes back to the follow-up: Return no longer runs an item.
        if conversing { clearSelection() }
      }
      if !conversing, arriving == nil { refresh(typed: changed) }
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
  /// What the last action could not do, until the configuration next changes.
  var actionProblem: String?

  /// The panel the screens show in (`PaletteSurface`).
  @ObservationIgnored weak var surface: (any PaletteSurface)?
  /// `measured`: the page shown now was measured before it showed, at this height.
  private func draw(_ measured: PageHeight? = nil) {
    surface?.present(measured.map { .measured($0) } ?? .content)
  }

  // MARK: Layers: details and the action panel

  private var baseTurn: String { conversing ? agent.turnID : command?.turn ?? "" }
  /// The details open over the page shown; those of an earlier page are not.
  private var openDetails: [Detail] { screen.details.first?.base == baseTurn ? screen.details : [] }
  var inDetail: Bool { !openDetails.isEmpty }
  /// The selected target's id as the page knows it.
  var selectedTarget: String? {
    page == nil || overlay != nil ? nil : results.first { $0.id == selection }?.row.id
  }
  /// Opens an item's content as its own page, with no model call and no extension run, and the item's
  /// own action as a row at its end. Its items may run the open command as the page it came from could.
  func openDetail(_ markdown: String, action: Row?, from result: Result?) {
    screen.details =
      openDetails + [
        Detail(
          page: Page(body: markdown, items: action.map { [$0] } ?? [], runs: !conversing), base: baseTurn,
          turn: pageTurn + ">" + (result?.row.id ?? ""))
      ]
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
    get { overlay?.selection ?? openDetails.last?.selection ?? screen.selection }
    set {
      let old = current.id
      if overlay != nil {
        overlay?.selection = newValue
      } else if inDetail {
        screen.details[screen.details.count - 1].selection = newValue
      } else {
        // The root's draft belongs to the selected command row.
        if newValue.id != old, !conversing, command == nil { base.arguments = [:] }
        screen.selection = newValue
      }
      guard newValue.id != old else { return }
      // The draft is gone, so the input takes the keys again.
      if command == nil { focusTarget = nil }
      surface?.present(.selection)
    }
  }
  var selection: String? { current.id }
  func select(_ id: String?) {
    current.touched = true
    returnQueued = false
    current.id = id
  }
  private func clearSelection() {
    current.touched = false
    current.id = nil
  }
  /// An edit starts the selection over: on the screen, which a rerun's new page shows, and in the detail
  /// open over it, which a submit command's edit leaves open, so Return sends the edited request.
  private func resetSelection() {
    screen.selection.reset = true
    if inDetail { screen.details[screen.details.count - 1].selection.reset = true }
  }
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
  /// it runs the view's actions.
  private var itemsWait: Bool { overlay == nil && (conversing || submits || page != nil) }
  /// Arrow keys: the first press enters the items under the input, and up from the first leaves them.
  func move(_ delta: Int) {
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

  // MARK: Return, arguments and the input

  /// The open command's Markdown body.
  var body: String? {
    guard let command, command.problem == nil else { return nil }
    return command.shown.view.body
  }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { body == nil ? [] : command?.shown.view.actions ?? [] }
  var extensionCommand: ExtensionCommand? { command.flatMap { extensions.commands[$0.id] } }
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? { command.flatMap { directory.name(of: $0.id) } }
  /// The open command runs on Return only (`submit` in its manifest).
  var submits: Bool { extensionCommand?.manifest.submit == true }
  /// Return runs the selected item. With none selected, a submit command sends what is typed and
  /// filled in as a submitted request, a page runs the view's own actions, and a conversation sends the
  /// follow-up.
  var selected: Result? {
    if let row = selectedRow { return row }
    guard !conversing, let command, submits else { return viewRow }
    return Result(
      provider: command.id,
      row: Row(
        id: "submit", title: commandName ?? "Run",
        actions: [.run(Address(input: input, arguments: filledArguments(of: command)))]))
  }
  /// What a submit sends besides the input: the declared arguments, including a value a run action set
  /// under a declared name. What it set under any other name stays out, or a Delete chosen once would be
  /// sent again with every later Return; the contract keeps confirmations to such names.
  private func filledArguments(of command: CommandState) -> [String: String] {
    let declared = Set(declaredArguments.map(\.name))
    return command.screen.arguments.filter { declared.contains($0.key) }
  }
  /// What Return does: the selected row's first action, or in a conversation with nothing selected,
  /// sending the follow-up. On a command row it enters the command with what was filled into its
  /// declared arguments.
  var returnAction: RowAction? {
    guard var action = selected?.row.actions.first else { return conversing ? .send(input) : nil }
    if command == nil, !drafted.isEmpty, case .run(var address) = action.kind {
      address.arguments = drafted
      action.kind = .run(address)
    }
    return action
  }
  /// The arguments the user can fill in: inside a command its own declared ones, at the root those of
  /// the selected extension command row. Empty when there are none.
  var declaredArguments: [ExtensionManifest.Argument] {
    guard !conversing, overlay == nil else { return [] }
    if command != nil { return extensionCommand?.manifest.arguments ?? [] }
    guard let row = results.first(where: { $0.id == selection }), row.row.id == "command" else { return [] }
    return extensions.commands[row.provider]?.manifest.arguments ?? []
  }
  /// Values filled in at the root for the selected command row; dropped when the selection moves or
  /// the panel is dismissed. Only the row itself takes them: an action chosen in ⌘K runs as captured.
  private var drafted: [String: String] {
    command == nil && !conversing && overlay == nil ? base.arguments : [:]
  }
  /// The current values by name: the open command's arguments, or the root draft. Unfilled is absent.
  var argumentValues: [String: String] { screen.arguments }
  /// Fills in a declared argument. Inside a command it is an edit like typing: it reruns the command,
  /// or in a submit command waits for Return.
  func setArgument(_ name: String, to value: String) {
    guard declaredArguments.contains(where: { $0.name == name }) else { return }
    let value = value.isEmpty ? nil : value
    guard command != nil else {
      base.arguments[name] = value
      return
    }
    command?.screen.arguments[name] = value
    resetSelection()
    refresh()
  }
  /// The argument slot that has the keyboard, by name; nil is the input. Only a declared name counts, so
  /// the input takes the keys back when the slots go away. A click into a field sets it too.
  var focusedArgument: String? {
    get { focusTarget.flatMap { name in declaredArguments.contains { $0.name == name } ? name : nil } }
    set { focusTarget = newValue }
  }
  private var focusTarget: String?
  /// Tab and Shift+Tab: the input, then each slot in order, round again. False when there are none.
  @discardableResult func moveFocus(_ delta: Int) -> Bool {
    let names = [nil] + declaredArguments.map(\.name)
    guard names.count > 1 else { return false }
    let index = names.firstIndex(of: focusedArgument) ?? 0
    focusTarget = names[(index + delta + names.count) % names.count]
    return true
  }
  /// Used by the native field, including paste and IME edits that arrive without a shortcut.
  func editInput(_ edit: InputEdit) {
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
    let left = arriving != nil && conversing
    showArrival()
    input = text
    if left { draw() }
  }
  /// The input the root's rows were composed for. Until the rows of an edit are there (normally after
  /// `RootCommand.patternHold`), the previous ones still show.
  private var composedInput = ""
  /// Return at the root waits for the rows composed for what is typed, so it never runs a row made for an
  /// earlier input. Unless the user picked a row, it also waits while a pattern that matched what is typed
  /// (a calculation, a `>` command for Shell) is still running: the input was meant for it, and its rows
  /// come first. Once that pattern answers with nothing, Return runs the first row, Ask agent included;
  /// if it failed, Return never asks the agent in its place. A picked row acts at once.
  var returnWaits: Bool {
    guard command == nil, !conversing, arriving == nil, overlay == nil else { return false }
    if composedInput != input { return true }
    guard !current.touched else { return false }
    return !search.runningPatterns.isEmpty || selected?.provider == "agent" && search.failedPattern
  }
  /// A pattern that matched what is typed is still running at the root, so the list has no Ask agent yet
  /// and an empty list is not "No results".
  var awaitsPattern: Bool { command == nil && !conversing && !search.runningPatterns.isEmpty }
  /// A Return that waits runs once `returnWaits` is over, as Return would then (`run`); an edit, a pick, a
  /// switch or hiding calls it off.
  private(set) var returnQueued = false
  /// Return, a button or a menu item: the action chosen, else what Return does, from the row it belongs
  /// to. A Return that waits for the root's rows runs once they are composed. What is not the screens'
  /// goes to the panel.
  func run(_ chosen: RowAction? = nil) {
    guard surface?.holdsReturn != true else { return }
    // What runs takes the input from dictation first, so a later transcript cannot rewrite it.
    speech?.stop(.run)
    if chosen == nil, returnWaits {
      returnQueued = true
      return
    }
    guard let (action, result) = pick(chosen), !activate(action, from: result) else { return }
    surface?.perform(.run(action, from: result))
  }

  // MARK: Switching screens

  /// The screen being switched to while its first content is on its way: a command (nil for the root)
  /// and its input. Until it arrives, or `arrivalDeadline` passes, the screen being left stays exactly as
  /// it was, so the panel's content and height change together in one step (`arrive`). Collapsing at once
  /// and growing on arrival was tried and rejected: a command with many items flashed small, then large.
  private struct Arrival {
    var command: CommandState?
    let input: String
    /// Going back (Escape): a second Escape waits for it instead of calling it off.
    var back = false
  }
  private var arriving: Arrival?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  var arrivalDeadline: Duration = .milliseconds(150)
  /// The command requests go to: the arriving one during a switch, else the open one.
  private var target: CommandState? {
    get { arriving.map(\.command) ?? command }
    set {
      if arriving != nil { arriving?.command = newValue } else { command = newValue }
    }
  }
  /// The open command's running request.
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var generation = 0
  /// Ends what the screen shown is waiting for: its request, the root's search and a waiting Return.
  func cancelWork() {
    returnQueued = false
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    search.cancel()
    command?.busy = false
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
  /// answered without a process switches at once. Ending a conversation waits the same way.
  private func arrive(_ command: CommandState?, input: String, back: Bool = false) {
    stopArriving()
    cancelWork()
    arriving = Arrival(command: command, input: input, back: back)
    refresh()
    guard arriving != nil else { return }
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
      base.arguments = [:]
    }
    let entering = arrival.command?.id != command?.id
    if entering, command == nil { base.arguments = [:] }
    command = arrival.command
    if entering || conversed { screen.selection.reset = true }
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
      let request = ProviderRequest(
        input: input, arguments: state.screen.arguments, submitted: state.next == .submission)
      let work = directory.work(state.id, request, rerun: state.next == .rerun, in: configuration)
      guard case .keepView = work else { return answer(work, of: state, request: request, typed: typed) }
      showArrival()
      publish()
      return
    }
    cancelWork()
    search.search(input, speaking: speech?.speaking == true) { [weak self] in self?.show($0) }
  }
  /// Answers a command's request as `work` says: what fails or is answered at once shows now, and a
  /// process's view once it is there, unless another request or screen replaced it meanwhile.
  private func answer(_ work: CommandWork, of state: CommandState, request: ProviderRequest, typed: Bool) {
    let speaking = speech?.speaking == true
    cancelWork()
    target?.next = .rerun
    let remembered = !typed || state.next != .rerun
    let source: (ProviderRequest) async throws -> ProviderView
    let report: (ProviderRequest, any Error) -> String
    switch work {
    case .keepView: return
    case .unavailable(let problem):
      // Back on or back again, it runs as when it is entered.
      target?.next = .address
      target?.context = nil
      target?.problem = problem
      showArrival()
      listed = []
      return publish()
    case .immediate(let view):
      target?.problem = nil
      showArrival()
      show(view, page: nil, of: state.id, request: request, turn: UUID().uuidString, remembered: remembered)
      return publish()
    case .deferred(let process, let failure):
      target?.problem = nil
      source = process
      report = failure
    }
    target?.busy = true
    let version = generation
    let turn = UUID().uuidString
    tasks.append(
      Task { [weak self] in
        var measured: PageHeight?
        do {
          if speaking { try await Task.sleep(for: .milliseconds(350)) }
          let view = try await source(request)
          guard let self, !Task.isCancelled, generation == version else { return }
          if view.close, request.submitted { return surface?.perform(.close) ?? () }
          let page = view.body.map { Page(body: $0, items: view.items, runs: true) }
          // Measured for this page's turn: one the renderer measured meanwhile, such as a list's detail
          // on an arrow key, says nothing about this one's height. What failed shows unmeasured at once.
          while arriving != nil, let page, let surface {
            let measurement = await surface.prepare(page, turn: turn)
            guard !Task.isCancelled, generation == version else { return }
            if measurement == .superseded { continue }
            if case .measured(let height) = measurement, height.turn == turn { measured = height }
            break
          }
          showArrival()
          show(view, page: page, of: state.id, request: request, turn: turn, remembered: remembered)
        } catch {
          guard let self, !Task.isCancelled, generation == version else { return }
          showArrival()
          if remembered { command?.context = nil }
          command?.problem = report(request, error)
          listed = []
        }
        guard let self, generation == version else { return }
        command?.busy = false
        publish(measured)
      })
    draw()
  }
  /// Waits until no work is left, including work a refresh started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks { await task.value }
      await search.settled()
    } while seen != generation
  }
  /// A command's view: a list ordered by what is typed, or a page.
  /// `remembered`: the user did not cause the request by typing, so the view becomes its context.
  private func show(
    _ view: ProviderView, page: Page?, of id: String, request: ProviderRequest, turn: String,
    remembered: Bool
  ) {
    command?.turn = turn
    command?.shown = CommandState.Shown(view: view, input: request.input, arguments: request.arguments)
    if remembered { command?.context = command?.shown }
    command?.page = page
    command?.busy = false
    listed = page == nil ? Ranking.order(view.items, provider: id, query: request.input) : []
  }
  /// The root's list for what is typed; a Return that waited for it runs now if it may.
  private func show(_ output: RootCommand.Output) {
    showArrival()
    listed = output.results
    composedInput = output.input
    publish()
    if returnQueued, !returnWaits {
      returnQueued = false
      run()
    }
  }
  /// Takes the user to an address. `origin` is the provider of the row it came from, which an address
  /// that omits its target names; any provider that is not a command means the root. An empty target
  /// is always the root. `submitted` marks the user activating a run action, which the first request says.
  func go(_ address: Address, from origin: String? = nil, submitted: Bool = false) {
    let own = origin.flatMap { directory.isCommand($0) ? $0 : nil }
    let target = address.extensionName == nil ? own : address.targetID
    // A run chosen in Agent History opens as a conversation over the list, which Escape returns to.
    if submitted, let run = directory.host(target)?.reopened(address.arguments ?? [:]) {
      return restore(run)
    }
    guard let destination = directory.destination(target) else {
      actionProblem = "No extension named \(target.map { Address(id: $0).extensionName ?? $0 } ?? "")"
      return
    }
    switch destination {
    case .settings: surface?.perform(.settings)
    case .agent: fill(address.input ?? input)
    case .root: arrive(nil, input: address.input ?? "")
    case .command(let id):
      let reopened = command?.id == id
      var state = command.flatMap { $0.id == id ? $0 : nil } ?? CommandState(id: id)
      state.screen.arguments = address.arguments ?? [:]
      state.next = submitted ? .submission : .address
      // Typing replaces the input, and an address without one keeps what is typed in the same command.
      let input = address.input ?? (reopened ? input : "")
      guard reopened, !conversing else { return arrive(state, input: input) }
      // The same screen: its request reruns in place.
      stopArriving()
      cancelWork()
      command = state
      self.input = input
    }
  }
  /// An external `wicket://` URL: the panel opens on its address. One that launched Wicket waits for the
  /// first extension scan, so the extension it names is known.
  func follow(_ address: Address) {
    guard !extensions.scanned else { return go(address) }
    Task { [weak self] in
      await self?.extensions.firstScan()
      self?.go(address)
    }
  }
  /// What the user runs, whoever asked: Return, a button, a menu item or a link. Moving between screens,
  /// sending questions and removing a hotkey happen here; effects on the panel and the system (copy,
  /// paste, open, recording a hotkey) are the panel's, and this returns false for them, except an open or
  /// reveal that `OpenPolicy` refuses: that does nothing but say why. `result` is the row it came from.
  @discardableResult
  func activate(_ action: RowAction, from result: Result? = nil) -> Bool {
    switch action.kind {
    case .run(let address):
      if let result { record(result) }
      // Activating a run action is the user's choice; following a link never is.
      go(address, from: result?.provider, submitted: !address.link)
    case .send(let text): send(text)
    case .detail(let markdown, let action): openDetail(markdown, action: action, from: result)
    case .hotkey(let target, record: false): store.bind(nil, to: target)
    case .open, .reveal:
      guard let refusal = OpenPolicy.refusal(action) else { return false }
      actionProblem = refusal
    case .copy, .paste, .clip, .hotkey: return false
    }
    return true
  }
  /// Only picks that root search can learn from: not inside a chosen command, and not fallbacks.
  func record(_ result: Result, input: String? = nil) {
    guard command == nil, result.row.id != "fallback" else { return }
    history.record(result.id, input: input ?? self.input)
  }
  /// Hides the panel's screens: what was over them, a switch and the work of the screen shown end. A
  /// conversation stays with its follow-up for when the panel shows again; anything else leaves the root
  /// with an empty input.
  func dismiss() {
    overlay = nil
    screen.selection.reset = true
    base.selection.reset = true
    // The root's draft stays under an empty question that is kept, for Escape to find; it goes with the
    // question's expiry (`reopen`).
    if !returnsOnEscape { base.arguments = [:] }
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
    base.arguments = [:]
    base.selection.reset = true
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
      screen.details = Array(openDetails.dropLast())
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
  var agentScreen: AgentPresentation? { conversation.map { AgentPresentation(agent, $0) } }
  /// A long question's header shows all of it, or two lines again.
  func toggleQuestion() { conversation?.expanded.toggle() }
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
    base.arguments = [:]
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
    let context = conversing ? (agent.question.isEmpty ? revealContext : nil) : commandContext(typed: true)
    converse {
      agent.ask(
        text, context: context?.text, from: context?.name, settings: questionSettings(keeping: agent.reopened)
      )
    }
  }
  /// What a question goes with: the agent settings at the Text size. A run reopened from Agent History
  /// keeps its agent, with that agent's defaults when another one is configured now.
  private func questionSettings(keeping kept: AgentConfiguration.Agent?) -> AgentConfiguration {
    var settings = configuration.agent
    if let kept, kept != settings.agent {
      settings = AgentConfiguration()
      settings.agent = kept
      settings.streamAnswers = configuration.agent.streamAnswers
    }
    settings.textSize = configuration.textSize
    return settings
  }
  private func restore(_ run: AgentHistory.Run) {
    converse { agent.restore(run, settings: questionSettings(keeping: run.agent)) }
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
    conversation = AgentScreen(back: .reveal(commandContext(typed: false)))
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
    let typed = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return contextView(typed: typed) == nil ? nil : extensionCommand?.manifest.name
  }
  /// What goes with a question asked from the open command: for a typed question its `context`, else
  /// what it shows unless that is an error. Nil at the root and for the host's own commands.
  private func contextView(typed: Bool) -> CommandState.Shown? {
    guard let command, extensionCommand != nil else { return nil }
    return typed ? command.context : command.problem == nil ? command.shown : nil
  }
  /// The open extension command and what it showed (`contextView`), for the agent's first question.
  private func commandContext(typed: Bool) -> AgentContext? {
    guard let shown = contextView(typed: typed), let owner = extensionCommand else { return nil }
    return AgentContext(owner, shown: shown)
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
  /// A run the user did not watch (a hotkey's, `LauncherModel.press`): its command shows its view or
  /// report, as if Return had run it, and nothing runs again.
  func adopt(
    _ program: ExtensionCommand, request: ProviderRequest, view: ProviderView? = nil, page: Page? = nil,
    turn: String = "", measured: PageHeight? = nil, problem: String? = nil
  ) {
    cancelWork()
    var state = CommandState(id: program.id, screen: Screen(arguments: request.arguments), next: .rerun)
    state.problem = problem
    // An arrival sets the input without a rerun.
    arriving = Arrival(command: state, input: request.input)
    showArrival()
    listed = []
    clearSelection()
    if let view {
      show(view, page: page, of: program.id, request: request, turn: turn, remembered: true)
      retainSelection()
    }
    draw(measured)
  }
}
