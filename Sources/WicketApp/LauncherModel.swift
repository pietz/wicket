import AppKit
import Observation

@MainActor @Observable
final class LauncherModel {
  /// The root's screen, the conversation's, and the open command's in `command`.
  private var search = Screen()
  private var conversation = Screen()
  /// The screen shown: the conversation, the open command's, or the root's.
  private var screen: Screen {
    get { agent.active ? conversation : command?.screen ?? search }
    set {
      if agent.active {
        conversation = newValue
      } else if command != nil {
        command?.screen = newValue
      } else {
        search = newValue
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
        screen.selection.reset = true
        // Typing in a conversation goes back to the follow-up: Return no longer runs an item.
        if agent.active { clearSelection() }
      }
      if !agent.active, arriving == nil { refresh(typed: changed) }
    }
  }
  let agent: AgentSession
  let extensions: ExtensionHost
  /// The list at search and inside a command.
  private var listed: [Result] {
    get { command?.screen.rows ?? search.rows }
    set {
      if command != nil { command?.screen.rows = newValue } else { search.rows = newValue }
      sizeList()
    }
  }
  /// The rows the list card is sized for: more show at once, fewer only after 300 ms, so a late batch
  /// such as file results does not make the panel shrink and grow again while typing. The pause counts
  /// from the first shorter list and is not restarted by later ones; once no source is pending the list
  /// is final and sized at once. A list for another screen is sized at once too: the hold is for
  /// results of one screen arriving late.
  private(set) var sizedRows = 1
  private var shrinking: Task<Void, Never>?
  private var sizedFor: String?
  private func sizeList(now: Bool = false) {
    let count = max(1, min(results.count, 8))
    let shown = command?.id
    let settled = root.pending.isEmpty && command?.busy != true
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
      onResultsChange?()
    }
  }
  /// What the arrow keys walk: the action panel's rows, the open page's targets in reading order, else
  /// the list.
  var results: [Result] {
    if let overlay { return overlay.rows }
    guard let page else { return agent.active ? [] : listed }
    let provider = agent.active ? "answer" : command?.id ?? ""
    return page.targets.map { Result(provider: provider, row: $0) }
  }
  /// The page shown: an open detail, the conversation's answer, or the open command's body.
  var page: Page? {
    if let detail = openDetails.last { return detail.page }
    if agent.active { return agent.question.isEmpty ? nil : agent.page }
    return command?.problem == nil ? command?.page : nil
  }
  /// Which page is shown, for the renderer (a new one starts at its top) and for clicks, which count
  /// only on the page they were made on.
  var pageTurn: String { openDetails.last?.turn ?? baseTurn }
  /// A command's list whose items carry a `detail` shows the selected one's beside it (`preview`). Not at
  /// the root, in a conversation, on a page or under the action panel. Keep split previews out of root
  /// search so ordinary keystrokes never have to render WebKit content.
  var splits: Bool {
    !agent.active && command != nil && page == nil && overlay == nil
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
  private var baseTurn: String { agent.active ? agent.turnID : command?.turn ?? "" }
  /// The details open over the page shown; those of an earlier page are not.
  private var openDetails: [Detail] { screen.details.first?.base == baseTurn ? screen.details : [] }
  var inDetail: Bool { !openDetails.isEmpty }
  /// The selected target's id as the page knows it.
  var selectedTarget: String? {
    page == nil || overlay != nil ? nil : results.first { $0.id == selection }?.row.id
  }
  /// Opens an item's content as its own page, with no model call and no extension run, and the item's
  /// own action as a row at its end. Its items may run the open command as the page it came from could.
  private func openDetail(_ markdown: String, action: Row?, from result: Result?) {
    screen.details =
      openDetails + [
        Detail(
          page: Page(body: markdown, items: action.map { [$0] } ?? [], runs: !agent.active), base: baseTurn,
          turn: pageTurn + ">" + (result?.row.id ?? ""))
      ]
    onResultsChange?()
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
    guard !agent.active, let command, body != nil, !inDetail else { return nil }
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
    onResultsChange?()
  }
  /// Back to the screen ⌘K was pressed on, with its selection as it was.
  private func closeActions() {
    guard overlay != nil else { return }
    overlay = nil
    reconcileSelection()
    sizeList(now: true)
    onResultsChange?()
  }
  /// What Return or a menu item runs, and the row it came from. An action chosen in the action panel
  /// closes it and belongs to the row the panel was opened for.
  func pick(_ chosen: RowAction? = nil) -> (action: RowAction, from: Result?)? {
    guard let action = chosen ?? returnAction else { return nil }
    guard let overlay else { return (action, selected) }
    closeActions()
    return (action, overlay.source)
  }
  private(set) var command: CommandState? {
    didSet { if command?.id != oldValue?.id { command?.screen.selection.reset = true } }
  }
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
  private var deadline: Task<Void, Never>?
  var arrivalDeadline: Duration = .milliseconds(150)
  /// Prepares an arriving page before it is shown: the controller renders and measures it, so the
  /// card's height is known when the page appears. Arguments are the page and its turn.
  var preparePage: ((Page, String) async -> Void)?
  /// The command requests go to: the arriving one during a switch, else the open one.
  private var target: CommandState? {
    get { arriving.map(\.command) ?? command }
    set {
      if arriving != nil { arriving?.command = newValue } else { command = newValue }
    }
  }
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
        if newValue.id != old, !agent.active, command == nil { search.arguments = [:] }
        screen.selection = newValue
      }
      guard newValue.id != old else { return }
      // The draft is gone, so the input takes the keys again.
      if command == nil { focusTarget = nil }
      onSelectionChange?()
    }
  }
  var selection: String? { current.id }
  /// The page paints its selection from here, at once rather than with the next render.
  var onSelectionChange: (() -> Void)?
  func select(_ id: String?) {
    current.touched = true
    returnQueued = false
    current.id = id
  }
  private func clearSelection() {
    current.touched = false
    current.id = nil
  }
  /// Each source owns its message. Configuration and hotkey problems live in the store.
  var actionProblem: String?
  var installProblem: String?
  func clearTransientProblems() { actionProblem = nil }
  var problem: String? {
    store.problem ?? store.hotkeyProblem ?? store.bindingProblem ?? installProblem ?? actionProblem
  }
  var questionExpanded = false
  var conversationHeaderHeight: CGFloat = 32 {
    didSet { if conversationHeaderHeight != oldValue { onResultsChange?() } }
  }
  var confirmationHeight: CGFloat = 210 {
    didSet { if confirmationHeight != oldValue { onResultsChange?() } }
  }
  func reopen(now: Date = Date()) {
    clipboard?.expire(now: now)
    agentHistory?.expire(now: now)
    let conversed = agent.active
    guard agent.reopen(now: now) else { return }
    cancelWork()
    if conversed { inheritConversation(into: &search) }
    if command != nil { search.selection.reset = true }
    command = nil
    input = ""
  }
  /// Every pasteboard write of Wicket's: its copy and paste actions.
  func writePasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  /// Writes a copy or paste action's content: its text, or a kept image resolved from its ID now. False, with
  /// the reason shown, when the image is gone.
  func writePasteboard(_ kind: RowAction.Kind) -> Bool {
    switch kind {
    case .copy(let text), .paste(let text): writePasteboard(text)
    case .clip(let id, _):
      guard clipboard?.write(id) == true else {
        actionProblem = "This image is no longer in the clipboard history"
        return false
      }
    default: return false
    }
    return true
  }
  /// The one owner of configuration. The model only reads it.
  let store: ConfigurationStore
  var configuration: Configuration { store.configuration }
  /// Called after every successful or failed configuration load, once the model has reacted.
  var onConfigurationChange: (Configuration?, String?) -> Void = { _, _ in }
  private(set) var voice: VoiceInput?
  private let makeTranscriber: () -> any Transcriber
  private let timingURL: URL
  var takesSpeech: Bool { !agent.busy && agent.permissions.isEmpty }
  func stopVoice(_ reason: VoiceStop) { voice?.stop(reason) }
  func armVoice() { prepareVoice()?.arm() }
  func toggleVoice() { prepareVoice()?.toggle() }
  private func prepareVoice() -> VoiceInput? {
    guard configuration.voice.enabled, takesSpeech else { return nil }
    if voice == nil {
      voice = VoiceInput(
        transcriber: makeTranscriber,
        timingURL: timingURL,
        write: { [weak self] text in
          guard let self, takesSpeech else {
            self?.stopVoice(.busy)
            return
          }
          // Like typing, speech during a screen switch switches at once; a transcript is the whole input.
          showArrival()
          input = text
        })
    }
    voice?.onPermissionFinished = { [weak self] in self?.onVoicePermissionFinished?() }
    return voice
  }
  /// Used by the native field, including paste and IME edits that arrive without a shortcut.
  func editInput(_ text: String) {
    stopVoice(.edit)
    // Typing in the action panel's empty field closes it, and what the field shows is the input: never
    // joined to the earlier input, which would rewrite the field under an input method's marked text.
    closeActions()
    // Typing while a command is being entered goes to it: the switch happens now, and what was added to
    // the input being left is what is typed into the new one.
    if let arrival = arriving {
      let old = input
      showArrival()
      input = text.hasPrefix(old) ? arrival.input + text.dropFirst(old.count) : text
      return
    }
    input = text
  }
  func keyPressed(_ action: PaletteKeyAction) -> Bool {
    return voice?.keyPressed(isEscape: action == .dismiss) ?? false
  }
  var onVoicePermissionFinished: (() -> Void)?
  var onSettings: () -> Void = {}
  /// Hides the panel: an extension's answer to a submitted request said it is done (`ProviderView.close`).
  var onClose: () -> Void = {}
  var onResultsChange: (() -> Void)?
  /// The search at the root.
  let root: RootCommand
  /// The open command's running request.
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  private let history: UsageHistory
  var extensionCommand: ExtensionCommand? { command.flatMap { extensions.commands[$0.id] } }
  let clipboard: ClipboardHistory?
  let agentHistory: AgentHistory?
  /// Where addresses resolve: the extensions' commands and the host's.
  let directory: CommandDirectory
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? { command.flatMap { directory.name(of: $0.id) } }

  init(
    apps: (any Provider)? = nil, files: FilesProvider? = nil, clipboard: ClipboardHistory? = nil,
    agentHistory: AgentHistory? = nil, history: UsageHistory,
    folder: URL = FileManager.default.temporaryDirectory, bundled: URL? = ExtensionHost.bundledFolder,
    transcriber: (() -> any Transcriber)? = nil
  ) {
    self.clipboard = clipboard
    self.agentHistory = agentHistory
    makeTranscriber = transcriber ?? { AppleTranscriber() }
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    timingURL = folder.appending(path: "voice-timing.txt")
    agent = AgentSession(folder: folder)
    agent.history = agentHistory
    extensions = ExtensionHost(folder: folder, bundled: bundled)
    directory = CommandDirectory(
      extensions: extensions, hosts: [clipboard as (any HostCommand)?, agentHistory].compactMap { $0 })
    root = RootCommand(apps: apps, files: files, directory: directory, store: store, history: history)
    self.history = history
    let inputChanged: () -> Void = { [weak self] in
      guard let self else { return }
      if !takesSpeech { stopVoice(.busy) }
      // A permission card needs to be seen.
      if !agent.permissions.isEmpty { closeActions() }
      onResultsChange?()
    }
    agent.onChange = inputChanged
    extensions.onCatalogChange = { [weak self] in self?.sourcesChanged($0) }
    store.onChange = { [weak self] configuration, problem in
      guard let self else { return }
      if let configuration {
        extensions.settings = configuration.extensions
        if !configuration.voice.enabled { stopVoice(.disabled) }
        clipboard?.configure(enabled: configuration.isEnabled("clipboard", extensions: []))
        if configuration != applied {
          clearTransientProblems()
          // Of a configuration, only a source switched on or off changes what a command answers.
          let ids = extensions.ids
          let switched = Set(configuration.sources(extensions: ids).map(\.id)).filter {
            applied.isEnabled($0, extensions: ids) != configuration.isEnabled($0, extensions: ids)
          }
          applied = configuration
          sourcesChanged(switched)
        }
        onResultsChange?()
      }
      onConfigurationChange(configuration, problem)
    }
  }
  /// The configuration last reacted to.
  private var applied = Configuration()
  /// Goes to a conversation that `start` begins: what was over the screen, a switch on its way and the
  /// screen's work end, and the input is the conversation's.
  private func converse(_ start: () -> Void) {
    origin = nil
    overlay = nil
    stopArriving()
    cancelWork()
    search.arguments = [:]
    start()
    questionExpanded = false
    clearSelection()
    input = ""
  }
  private func cancelWork() {
    returnQueued = false
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    root.cancel()
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
      guard let self, (try? await Task.sleep(for: arrivalDeadline)) != nil, arriving != nil else { return }
      showArrival()
      publish()
    }
  }
  /// Makes the arriving screen the visible one. The caller publishes its content in the same turn.
  private func showArrival() {
    guard let arrival = arriving else { return }
    overlay = nil
    let conversed = agent.active
    if conversed { agent.reset() }
    let entering = arrival.command?.id != command?.id
    if entering, command == nil { search.arguments = [:] }
    command = arrival.command
    if conversed { inheritConversation(into: &screen) }
    if entering { screen.selection.reset = true }
    input = arrival.input  // No refresh while arriving: its request is already answered or running.
    stopArriving()
    if entering { listed = [] }
  }
  /// The screen shown when a conversation ends, other than by Escape from an empty question, takes over
  /// the conversation's input and selection, as when all screens shared one.
  private func inheritConversation(into screen: inout Screen) {
    screen.input = conversation.input
    screen.selection = conversation.selection
  }
  /// What sources answer changed without the user: the installed apps, the extension catalog or which
  /// sources are on. The root composes again. An open command reruns only when `ids` names it (its
  /// manifest changed, it went away, or it was switched on or off), which also cancels its running
  /// request; anything else would replace what the user is looking at for no reason of its own.
  func sourcesChanged(_ ids: Set<String>) {
    if let id = target?.id, !ids.contains(id) { return }
    refresh()
  }
  /// `typed`: the input was edited, which a command's context ignores unless an address set it.
  func refresh(typed: Bool = false) {
    guard !agent.active || arriving != nil else { return }
    let speaking = voice?.active == true
    let input = arriving?.input ?? self.input
    if let state = target {
      let source = directory.source(state.id)
      let extensionCommand = extensions.commands[state.id]
      let available = directory.isAvailable(state.id, in: configuration)
      // A submit command runs only when an address is followed, Return included: typing, voice and
      // refreshes leave its view and a running request alone, and nothing stays selected. One switched
      // off or removed stops like any other.
      if state.next == .rerun, extensionCommand?.manifest.submit == true, available {
        showArrival()
        publish()
        return
      }
      cancelWork()
      target?.next = .rerun
      let remembered = !typed || state.next != .rerun
      guard let source, available else {
        // Back on or back again, it runs as when it is entered.
        target?.next = .address
        target?.context = nil
        target?.problem =
          source == nil
          ? "This extension was removed. Press Esc to go back."
          : "\(directory.name(of: state.id) ?? state.id) is switched off. Switch it on in Settings, Extensions, or press Esc to go back."
        showArrival()
        listed = []
        publish()
        return
      }
      target?.problem = nil
      let request = ProviderRequest(
        input: input, arguments: state.screen.arguments, submitted: state.next == .submission)
      if let view = directory.immediateView(state.id, request) {
        showArrival()
        show(view, page: nil, of: state.id, request: request, turn: UUID().uuidString, remembered: remembered)
        publish()
        return
      }
      target?.busy = true
      let version = generation
      let turn = UUID().uuidString
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await source(request)
            guard let self, !Task.isCancelled, generation == version else { return }
            // A submitted request that is done closes the panel, as the user hiding it would, without
            // showing its view; the effect (a moved window) is the feedback.
            if view.close, request.submitted { return onClose() }
            let page = view.body.map { Page(body: $0, items: view.items, runs: true) }
            if arriving != nil, let page, let preparePage {
              await preparePage(page, turn)
              guard !Task.isCancelled, generation == version else { return }
            }
            showArrival()
            show(view, page: page, of: state.id, request: request, turn: turn, remembered: remembered)
          } catch {
            guard let self, !Task.isCancelled, generation == version else { return }
            showArrival()
            if remembered { command?.context = nil }
            command?.problem =
              extensionCommand.map { report($0, request: request, error: error) }
              ?? error.localizedDescription
            listed = []
          }
          guard let self, generation == version else { return }
          command?.busy = false
          publish()
        })
      onResultsChange?()
      return
    }
    cancelWork()
    root.search(input, speaking: speaking) { [weak self] in self?.show($0) }
  }
  /// Waits until no work is left, including work a refresh started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks { await task.value }
      await root.settled()
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
      onReturnReady?()
    }
  }
  /// The input the root's rows were composed for. Until the rows of an edit are there (normally after
  /// `RootCommand.patternHold`), the previous ones still show.
  private var composedInput = ""
  /// Return at the root waits for the rows composed for what is typed, so it never runs a row made for an
  /// earlier input, and never asks the agent only because a pattern that matched what is typed (a `>`
  /// command for Shell) has not answered with rows: the input was meant for it. A picked row acts at once.
  var returnWaits: Bool {
    guard command == nil, !agent.active, arriving == nil, overlay == nil else { return false }
    return composedInput != input
      || !current.touched && selected?.provider == "agent" && root.awaitsPattern
  }
  /// A Return that waits runs once `returnWaits` is over; an edit, a pick, a switch or hiding calls it off.
  var returnQueued = false
  var onReturnReady: (() -> Void)?
  /// The one step after a screen's content changed: the selection follows it, then the panel draws it.
  private func publish() {
    retainSelection()
    onResultsChange?()
  }
  private func retainSelection() {
    guard overlay == nil else { return }
    let rows = results
    if current.reset { current.touched = false }
    if !current.touched {
      current.id = itemsWait ? nil : rows.first?.id
    } else if let chosen = current.id, !rows.contains(where: { $0.id == chosen }) {
      // On a page a target that went away takes the selection with it: Return never moves to a neighbor.
      if page != nil {
        clearSelection()
        current.reset = false
        return
      }
      if !root.pending.isEmpty {
        current.reset = false
        return
      }
      let index = current.previous.firstIndex { $0 == chosen } ?? 0
      current.id = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
    }
    current.reset = false
    current.previous = rows.map(\.id)
  }
  /// Back on a screen or page as the user left it: its own selection, kept unless its rows changed meanwhile.
  private func reconcileSelection() {
    current.reset = false
    retainSelection()
  }
  var prominentFirst: Bool { results.first.map { $0.row.prominent == true } ?? false }
  /// The open command's Markdown body.
  var body: String? {
    guard let command, command.problem == nil else { return nil }
    return command.shown.view.body
  }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { body == nil ? [] : command?.shown.view.actions ?? [] }
  /// Whether the input has the first say, so items wait for an arrow key and typing leaves them: in a
  /// conversation Return sends the follow-up, in a submit command it sends the request, and on a page
  /// it runs the view's actions.
  private var itemsWait: Bool { overlay == nil && (agent.active || submits || page != nil) }
  /// The open command runs on Return only (`submit` in its manifest).
  var submits: Bool { extensionCommand?.manifest.submit == true }
  /// Return runs the selected item. With none selected, a submit command sends what is typed and
  /// filled in as a submitted request, a page runs the view's own actions, and a conversation sends the
  /// follow-up.
  var selected: Result? {
    if let row = selectedRow { return row }
    guard !agent.active, let command, submits else { return viewRow }
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
    guard var action = selected?.row.actions.first else { return agent.active ? .send(input) : nil }
    if command == nil, !drafted.isEmpty, case .run(var address) = action.kind {
      address.arguments = drafted
      action.kind = .run(address)
    }
    return action
  }
  /// The arguments the user can fill in: inside a command its own declared ones, at the root those of
  /// the selected extension command row. Empty when there are none.
  var declaredArguments: [ExtensionManifest.Argument] {
    guard !agent.active, overlay == nil else { return [] }
    if command != nil { return extensionCommand?.manifest.arguments ?? [] }
    guard let row = results.first(where: { $0.id == selection }), row.row.id == "command" else { return [] }
    return extensions.commands[row.provider]?.manifest.arguments ?? []
  }
  /// Values filled in at the root for the selected command row; dropped when the selection moves or
  /// the panel is dismissed. Only the row itself takes them: an action chosen in ⌘K runs as captured.
  private var drafted: [String: String] {
    command == nil && !agent.active && overlay == nil ? search.arguments : [:]
  }
  /// The current values by name: the open command's arguments, or the root draft. Unfilled is absent.
  var argumentValues: [String: String] { screen.arguments }
  /// Fills in a declared argument. Inside a command it is an edit like typing: it reruns the command,
  /// or in a submit command waits for Return.
  func setArgument(_ name: String, to value: String) {
    guard declaredArguments.contains(where: { $0.name == name }) else { return }
    let value = value.isEmpty ? nil : value
    guard command != nil else {
      search.arguments[name] = value
      return
    }
    command?.screen.arguments[name] = value
    command?.screen.selection.reset = true
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
  /// The one dispatcher for moving between views and sending questions, whoever asked: Return, a button,
  /// a menu item or a link. Effects on the panel and the system (copy, paste, open) are not handled here
  /// and return false, except an open or reveal that `OpenPolicy` refuses: that does nothing but say why.
  /// `result` is the row the action came from, if any.
  @discardableResult
  func activate(_ action: RowAction, from result: Result? = nil) -> Bool {
    switch action.kind {
    case .run(let address):
      if let result { record(result) }
      // Activating a run action is the user's choice; following a link never is.
      go(address, from: result?.provider, submitted: !address.link)
    case .send(let text): send(text)
    case .detail(let markdown, let action): openDetail(markdown, action: action, from: result)
    case .hotkey(let target, record: true):
      recorder.record(target, in: window, store: store) { [weak self] in self?.pauseHotkeys($0) }
    case .hotkey(let target, record: false): store.bind(nil, to: target)
    case .open, .reveal:
      guard let refusal = OpenPolicy.refusal(action) else { return false }
      actionProblem = refusal
    case .copy, .paste, .clip: return false
    }
    return true
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
    case .settings: onSettings()
    case .agent: fill(address.input ?? input)
    case .root: arrive(nil, input: address.input ?? "")
    case .command(let id):
      let reopened = command?.id == id
      var state = command.flatMap { $0.id == id ? $0 : nil } ?? CommandState(id: id)
      state.screen.arguments = address.arguments ?? [:]
      state.next = submitted ? .submission : .address
      // Typing replaces the input, and an address without one keeps what is typed in the same command.
      let input = address.input ?? (reopened ? input : "")
      guard reopened, !agent.active else { return arrive(state, input: input) }
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
  /// Who Return asks: a draft goes to the agent configured now, since settings apply when it is sent.
  var askingName: String { agent.question.isEmpty ? configuration.agent.agent.title : agent.agentName }
  func send(_ text: String? = nil) {
    let text = text ?? input
    guard !agent.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Only a new conversation asked from an extension's command learns what it showed.
    let context =
      agent.active ? (agent.question.isEmpty ? origin?.context : nil) : commandContext(typed: true)
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
  /// Cmd+Return: asks what is typed. With nothing typed it opens an empty conversation about what is on
  /// screen, which Escape leaves for exactly that screen again.
  func askAgent() {
    closeActions()
    guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return send() }
    guard !agent.active else { return }
    // A switch still on its way is called off with its request, which would otherwise answer into the
    // screen under the conversation. That screen's own work already stopped when the switch began.
    if arriving != nil {
      stopArriving()
      cancelWork()
    }
    origin = Origin(context: commandContext(typed: false))
    agent.open(settings: configuration.agent)
    clearSelection()
    input = ""
  }
  /// Where an empty conversation opened by Cmd+Return came from: what its first question tells the
  /// agent. The screen under it stays as it was, and Escape returns to it.
  private struct Origin {
    let context: (text: String, name: String)?
  }
  private var origin: Origin?
  /// Escape leaves the empty conversation for the screen under it, as Cmd+Return found it.
  var returnsOnEscape: Bool { agent.active && agent.question.isEmpty && origin != nil }
  /// The extension whose view Cmd+Return would send with the question, for the footer and placeholder.
  var askingAbout: String? {
    if agent.active { return agent.question.isEmpty ? origin?.context?.name : nil }
    let typed = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return contextView(typed: typed) == nil ? nil : extensionCommand?.manifest.name
  }
  /// What goes with a question asked from the open command: for a typed question its `context`, else
  /// what it shows unless that is an error. Nil at the root and for the host's own commands.
  private func contextView(typed: Bool) -> CommandState.Shown? {
    guard let command, extensionCommand != nil else { return nil }
    return typed ? command.context : command.problem == nil ? command.shown : nil
  }
  /// The open extension command and what it showed (`contextView`), as a `<context>` block for the
  /// agent, with the command's name for the question header.
  private func commandContext(typed: Bool) -> (text: String, name: String)? {
    guard let shown = contextView(typed: typed), let owner = extensionCommand else { return nil }
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
    if view.count > Self.contextLimit {
      view = String(view.prefix(Self.contextLimit)) + "\n[cut: the view was longer than this]"
    }
    let name = owner.manifest.name
    var asked =
      "The user asked from the \(name) command (\(owner.folder.path), folder `\(owner.folder.lastPathComponent)`)"
    asked += ", input \(json(shown.input))"
    if !shown.arguments.isEmpty { asked += ", arguments \(json(shown.arguments))" }
    return ("<context>\n\(asked).\nIt showed:\n\(view)\n</context>", name)
  }
  /// About 4 KB of the open view goes to the agent.
  static let contextLimit = 4000
  /// The `agent` action: the text becomes the input and nothing is sent. In a conversation the next
  /// Return is the follow-up. Anywhere else an open command is left and an empty conversation opens
  /// with the text as its unsent first question.
  func fill(_ text: String) {
    if !agent.active {
      converse {
        command = nil
        agent.open(settings: configuration.agent)
      }
    }
    editInput(text)
  }
  func dismiss() {
    recorder.stop()
    overlay = nil
    screen.selection.reset = true
    search.selection.reset = true
    search.arguments = [:]
    focusTarget = nil
    stopVoice(.hidden)
    agent.hidden()
    stopArriving()
    // Hiding stops a running command, also under a conversation.
    cancelWork()
    if agent.active { return }
    command = nil
    input = ""
    sizeList(now: true)
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
      onResultsChange?()
      return true
    }
    if returnsOnEscape {
      // Cmd+Return's empty conversation goes back to the screen under it as it was: nothing reruns.
      origin = nil
      agent.reset()
      reconcileSelection()
      onResultsChange?()
      return true
    }
    if agent.active {
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
  /// What a row's hotkey is bound to: an extension's command row, one of its manifest items (at the root,
  /// or inside the command when the view lists it by the item's id) or a host command. Nil for a row with
  /// no address of its own, such as an app, a file or a fallback.
  func hotkeyTarget(of result: Result) -> HotkeyTarget? {
    if CommandDirectory.isRootRow(result) { return HotkeyTarget(target: result.provider) }
    guard let owner = extensions.commands[result.provider] else { return nil }
    if command == nil, result.row.id == "command" { return HotkeyTarget(target: owner.id) }
    var item = result.row.id
    if command == nil {
      // At the root an item's id is prefixed (`ExtensionCommand.rootItems`).
      guard item.hasPrefix("item:") else { return nil }
      item.removeFirst(5)
    }
    guard owner.manifest.items?.contains(where: { $0.id == item }) == true else { return nil }
    return HotkeyTarget(target: owner.id, item: item)
  }
  /// The hotkey a row shows at its trailing edge.
  func hotkey(of result: Result) -> Shortcut? {
    guard !configuration.hotkeys.isEmpty, let target = hotkeyTarget(of: result) else { return nil }
    return configuration.hotkeys.first { $0.target == target }?.keys
  }
  /// Records a row's hotkey: Set Hotkey… (`activate`) makes the next shortcut pressed its hotkey, under
  /// the launcher's rules.
  let recorder = ShortcutRecorder()
  /// The panel the recorder listens in, named because Wicket is not the active app while it is key.
  weak var window: NSWindow?
  /// Pauses every global hotkey of Wicket's while a recorder listens (AppDelegate).
  var pauseHotkeys: (Bool) -> Void = { _ in }
  /// Whether Set Hotkey… is recording this row's hotkey.
  func recordsHotkey(of result: Result) -> Bool {
    recorder.target != nil && recorder.target == hotkeyTarget(of: result)
  }
  /// A hotkey bound to `target` was pressed. A manifest item whose first action runs an extension's program
  /// runs it now with a submitted request, as Return on the item would, with the panel hidden; a view that
  /// says it is done keeps it hidden, and any other view or a failure calls `show` and shows the command
  /// with it, such as why no window moved. Anything else shows the panel on the
  /// address: a command, a host command, or an item whose action opens a view. Nothing is recorded as usage.
  func press(_ target: HotkeyTarget, show: () -> Void) async {
    let owner = target.target.flatMap { extensions.commands[$0] }
    let item = target.item.flatMap { id in owner?.manifest.items?.first { $0.id == id } }
    // A switched-off extension's items run nothing: its address shows that it is off.
    guard let owner, let item, case .run(let address)? = item.actions.first?.kind,
      configuration.isEnabled(owner.id, extensions: extensions.ids)
    else {
      show()
      return go(target.address)
    }
    let id = address.extensionName == nil ? owner.id : address.targetID
    guard !address.link, let id, let program = extensions.commands[id], program.manifest.command != nil,
      configuration.isEnabled(id, extensions: extensions.ids)
    else {
      show()
      return go(address, from: owner.id, submitted: !address.link)
    }
    let request = ProviderRequest(
      input: address.input ?? "", arguments: address.arguments ?? [:], submitted: true)
    let view: ProviderView
    do {
      view = try await extensions.view(program, request: request)
    } catch is CancellationError {
      return
    } catch {
      show()
      return showRun(program, request: request, problem: report(program, request: request, error: error))
    }
    guard !view.close else { return }
    let turn = UUID().uuidString
    let page = view.body.map { Page(body: $0, items: view.items, runs: true) }
    if let page, let preparePage { await preparePage(page, turn) }
    show()
    showRun(program, request: request, view: view, page: page, turn: turn)
  }
  /// A run the user did not watch: its command shows its view or report, as if Return had run it, and
  /// nothing runs again.
  private func showRun(
    _ program: ExtensionCommand, request: ProviderRequest, view: ProviderView? = nil, page: Page? = nil,
    turn: String = "", problem: String? = nil
  ) {
    origin = nil
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
    onResultsChange?()
  }
  private func report(_ command: ExtensionCommand, request: ProviderRequest, error: any Error) -> String {
    "Extension: \(command.folder.path)\nCommand: \(command.manifest.command ?? [])\nRequest: \(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self))\n\n\(error.localizedDescription)"
  }
  /// Only picks that root search can learn from: not inside a chosen command, and not fallbacks.
  func record(_ result: Result, input: String? = nil) {
    guard command == nil, result.row.id != "fallback" else { return }
    history.record(result.id, input: input ?? self.input)
  }
  func finish() async {
    stopVoice(.quit)
    await voice?.shutdown?.value
    cancelWork()
    await extensions.shutdown()
    await agent.shutdown()
    await history.finish()
    await clipboard?.finish()
    await agentHistory?.finish()
  }
}
