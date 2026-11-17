import AppKit
import Observation

/// The command screen: an extension's, or a host command's (Clipboard History, Agent History). Nil at search.
struct CommandState {
  let id: String
  var arguments: [String: String] = [:]
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
  /// What a typed question tells the agent the command showed (`LauncherModel.commandContext`): the
  /// last view whose request the user did not cause by typing. Typing reruns never replace it, so a
  /// question typed into a command that is not `submit` sends the view it was asked about, not the
  /// rerun for its own text. Nil until such a request is answered, and after one fails.
  var context: Shown?
  /// The view's body as a page, with its items after it; nil for a list.
  var page: Page?
  var problem: String?
  var busy = false
  /// The running request has shown a view and goes on printing more (views over time): Escape stops it
  /// and stays on the last one.
  var live = false
  var turn = UUID().uuidString
}

@MainActor @Observable
final class LauncherModel {
  var input = "" {
    didSet {
      if input != oldValue {
        resetSelection = true
        // Typing in a conversation goes back to the follow-up: Return no longer runs an item.
        if agent.active { clearSelection() }
      }
      if !agent.active, arriving == nil { refresh(typed: input != oldValue) }
    }
  }
  let agent: AgentSession
  let extensions: ExtensionHost
  /// The list at search and inside a command.
  private var listed: [Result] = [] { didSet { sizeList() } }
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
    let screen = command?.id
    let settled = pending.isEmpty && command?.busy != true
    guard count < sizedRows, !now, !settled, screen == sizedFor else {
      shrinking?.cancel()
      shrinking = nil
      sizedFor = screen
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
    if let actionPanel { return actionPanel.rows }
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
  /// the root, in a conversation, on a page or under the action panel.
  var splits: Bool {
    !agent.active && command != nil && page == nil && actionPanel == nil
      && listed.contains { $0.row.detail != nil }
  }
  /// The selected item's detail, written with the view, so an arrow key shows it with no request; empty
  /// for an item without one. Its turn names the command, so the pane shows no other screen's page.
  var preview: (page: Page, turn: String)? {
    guard splits, let command else { return nil }
    let row = selectedRow?.row
    return (
      Page(body: row?.detail ?? "", runs: true, picture: row?.picture), Self.previewTurn(command.id, row?.id)
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
  /// An item's content opened as its own page, over the page it came from: the selection and the
  /// scroll position there come back with Escape. Details belong to one page (`base`); a new answer or
  /// view leaves them.
  private struct Detail {
    let page: Page
    let base: String
    let turn: String
    let selection: String?
    let touched: Bool
  }
  private var details: [Detail] = []
  private var openDetails: [Detail] { details.first?.base == baseTurn ? details : [] }
  var inDetail: Bool { !openDetails.isEmpty }
  /// The selected target's id as the page knows it.
  var selectedTarget: String? {
    page == nil || actionPanel != nil ? nil : results.first { $0.id == selection }?.row.id
  }
  /// Opens an item's content as its own page, with no model call and no extension run. Its items may
  /// run the open command as the page it came from could.
  private func openDetail(_ markdown: String, from result: Result?) {
    details = openDetails
    details.append(
      Detail(
        page: Page(body: markdown, runs: !agent.active), base: baseTurn,
        turn: pageTurn + ">" + (result?.row.id ?? ""), selection: selection, touched: selectionTouched))
    clearSelection()
    onResultsChange?()
  }
  /// The action panel (⌘K): a row's actions as rows of their own in place of the list or page, and where
  /// the user was, which Escape, ⌘K again and typing return to.
  private struct ActionPanel {
    let source: Result
    let rows: [Result]
    let selection: String?
    let touched: Bool
    let drafted: [String: String]
  }
  private var actionPanel: ActionPanel?
  /// The title of the row whose actions the panel lists; nil while it is closed.
  var actionsTitle: String? { actionPanel?.source.row.title }
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
  var offersActions: Bool { actionPanel == nil && actionSource.map { actions(of: $0).count > 1 } == true }
  /// ⌘K: lists the actions of `source`, else of the selected row or the view, as single-action rows, so
  /// arrows, Return and clicks work as in any list. Again, it returns to where the user was.
  func toggleActions(_ source: Result? = nil) {
    if actionPanel != nil { return closeActions() }
    guard arriving == nil, agent.permissions.isEmpty, let source = source ?? actionSource else { return }
    let rows = actions(of: source).enumerated().map { index, action in
      Result(
        provider: "actions",
        row: Row(id: String(index), title: action.label, icon: action.symbol, actions: [action]))
    }
    guard let first = rows.first else { return }
    actionPanel = ActionPanel(
      source: source, rows: rows, selection: selection, touched: selectionTouched, drafted: drafted)
    focusTarget = nil
    select(first.id)
    sizeList(now: true)
    onResultsChange?()
  }
  /// Back to where ⌘K was pressed, with the same selection.
  private func closeActions() {
    guard let panel = actionPanel else { return }
    actionPanel = nil
    returnTo(panel.selection, touched: panel.touched, drafted: panel.drafted)
    sizeList(now: true)
    onResultsChange?()
  }
  /// What Return or a menu item runs, and the row it came from. An action chosen in the action panel
  /// closes it and belongs to the row the panel was opened for.
  func pick(_ chosen: RowAction? = nil) -> (action: RowAction, from: Result?)? {
    guard let action = chosen ?? returnAction else { return nil }
    guard let panel = actionPanel else { return (action, selected) }
    closeActions()
    return (action, panel.source)
  }
  private(set) var isRefreshing = false
  private(set) var command: CommandState? {
    didSet { if command?.id != oldValue?.id { resetSelection = true } }
  }
  /// The screen being switched to while its first content is on its way: a command (nil for the root)
  /// and its input. Until it arrives, or `arrivalDeadline` passes, the screen being left stays exactly as
  /// it was, so the panel's content and height change together in one step (`arrive`).
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
  private var resetSelection = true
  private var previousRows: [String] = []
  private var selectionTouched = false
  /// Sources whose results for this input may still arrive: running pattern extensions and file search.
  private var pending: Set<String> = []
  private(set) var selection: String? {
    didSet {
      guard selection != oldValue else { return }
      drafted = [:]
      // The draft is gone, so the input takes the keys again.
      if command == nil { focusTarget = nil }
      onSelectionChange?()
    }
  }
  /// The page paints its selection from here, at once rather than with the next render.
  var onSelectionChange: (() -> Void)?
  func select(_ id: String?) {
    selectionTouched = true
    selection = id
  }
  private func clearSelection() {
    selectionTouched = false
    selection = nil
  }
  /// Each source owns its message. Configuration and hotkey problems live in the store.
  private(set) var providerProblem: String?
  var actionProblem: String?
  var installProblem: String?
  func clearTransientProblems() {
    providerProblem = nil
    actionProblem = nil
  }
  var problem: String? {
    store.problem ?? store.hotkeyProblem ?? store.bindingProblem ?? installProblem ?? actionProblem
      ?? providerProblem
  }
  var questionExpanded = false
  var historyExpanded = false
  var conversationHeaderHeight: CGFloat = 32 {
    didSet { if conversationHeaderHeight != oldValue { onResultsChange?() } }
  }
  var confirmationHeight: CGFloat = 210 {
    didSet { if confirmationHeight != oldValue { onResultsChange?() } }
  }
  func reopen(now: Date = Date()) {
    clipboard?.expire(now: now)
    agentHistory?.expire(now: now)
    guard agent.reopen(now: now) else { return }
    cancelWork()
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
  private let makeTranscriber: (() -> any Transcriber)?
  private let timingURL: URL
  var takesSpeech: Bool { !agent.busy && agent.permissions.isEmpty }
  func stopVoice(_ reason: VoiceStop) { voice?.stop(reason) }
  func armVoice() { prepareVoice()?.arm() }
  func toggleVoice() { prepareVoice()?.toggle() }
  private func prepareVoice() -> VoiceInput? {
    guard configuration.voice.enabled, takesSpeech else {
      VoiceLog.logger.log(
        "voice not armed: \(self.configuration.voice.enabled ? "agent busy or asking" : "disabled", privacy: .public)"
      )
      return nil
    }
    if voice == nil {
      voice = VoiceInput(
        transcriber: { [weak self] in
          self?.makeTranscriber?() ?? AppleTranscriber(microphoneUID: self?.configuration.voice.microphone)
        },
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
  /// The installed apps, the one source answered in process besides file search.
  private let apps: (any Provider)?
  private let files: FilesProvider?
  private var appRows: [Row] = []
  private var fileRows: [Row] = []
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  private var itemRows: [Ranking.Names] = []
  private var patterns: [String: Ranking.Pattern] = [:]
  /// Why the root list has a strong match, or nil when nothing matches strongly.
  private(set) var strongReason: String?
  private let history: UsageHistory
  var extensionCommand: ExtensionCommand? { command.flatMap { extensions.commands[$0.id] } }
  let clipboard: ClipboardHistory?
  let agentHistory: AgentHistory?
  /// The host's own commands, answered without a process.
  private func hostCommand(_ id: String) -> (@MainActor @Sendable (ProviderRequest) -> ProviderView)? {
    if let clipboard, clipboard.id == id { return { clipboard.view(for: $0) } }
    if let agentHistory, agentHistory.id == id { return { agentHistory.view(for: $0) } }
    return nil
  }
  /// What answers a command's requests: an extension's command through the host, or a host command.
  /// Nil when there is no such command.
  private func commandSource(_ id: String) -> (
    @MainActor (ProviderRequest) -> AsyncThrowingStream<(view: ProviderView, running: Bool), any Error>
  )? {
    if let command = extensions.commands[id] {
      let host = extensions
      return { host.views(command, request: $0) }
    }
    guard let view = hostCommand(id) else { return nil }
    return { request in
      AsyncThrowingStream {
        $0.yield((view(request), false))
        $0.finish()
      }
    }
  }
  /// What a command answers without waiting for anything: an extension's manifest items, or a host
  /// command. Nil when it runs a process.
  private func immediateView(_ id: String, _ request: ProviderRequest) -> ProviderView? {
    if let command = extensions.commands[id] {
      return command.manifest.command == nil ? ProviderView(items: command.ownItems(request.input)) : nil
    }
    return hostCommand(id)?(request)
  }
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? { command.flatMap { name(of: $0.id) } }
  private func name(of id: String) -> String? {
    extensions.commands[id]?.manifest.name
      ?? (id == clipboard?.id ? ClipboardHistory.title : id == agentHistory?.id ? AgentHistory.title : nil)
  }

  init(
    apps: (any Provider)? = nil, files: FilesProvider? = nil, clipboard: ClipboardHistory? = nil,
    agentHistory: AgentHistory? = nil, history: UsageHistory,
    folder: URL = FileManager.default.temporaryDirectory, bundled: URL? = ExtensionHost.bundledFolder,
    transcriber: (() -> any Transcriber)? = nil
  ) {
    self.clipboard = clipboard
    self.agentHistory = agentHistory
    makeTranscriber = transcriber
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    timingURL = folder.appending(path: "voice-timing.txt")
    agent = AgentSession(folder: folder)
    agent.history = agentHistory
    extensions = ExtensionHost(folder: folder, bundled: bundled)
    self.apps = apps
    self.files = files
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
  private func cancelWork() {
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    isRefreshing = false
    command?.busy = false
    command?.live = false
    pending.removeAll()
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
      retainSelection()
      onResultsChange?()
    }
  }
  /// Makes the arriving screen the visible one. The caller publishes its content in the same turn.
  private func showArrival() {
    guard let arrival = arriving else { return }
    actionPanel = nil
    if agent.active { agent.reset() }
    let entering = arrival.command?.id != command?.id
    command = arrival.command
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
  /// `typed`: the input was edited, which a command's context ignores unless an address set it.
  func refresh(typed: Bool = false) {
    guard !agent.active || arriving != nil else { return }
    let speaking = voice?.active == true
    let input = arriving?.input ?? self.input
    if let state = target {
      let source = commandSource(state.id)
      let extensionCommand = extensions.commands[state.id]
      // A submit command runs only when an address is followed, Return included: typing, voice and
      // refreshes leave its view and a running request alone, and nothing stays selected.
      if state.next == .rerun, extensionCommand?.manifest.submit == true, source != nil {
        showArrival()
        retainSelection()
        onResultsChange?()
        return
      }
      cancelWork()
      target?.next = .rerun
      let remembered = !typed || state.next != .rerun
      guard let source,
        state.id == agentHistory?.id || configuration.isEnabled(state.id, extensions: extensions.ids)
      else {
        target?.context = nil
        target?.problem =
          source == nil
          ? "This extension was removed. Press Esc to go back."
          : "\(name(of: state.id) ?? state.id) is switched off. Switch it on in Settings, Extensions, or press Esc to go back."
        showArrival()
        listed = []
        retainSelection()
        onResultsChange?()
        return
      }
      target?.problem = nil
      let request = ProviderRequest(
        input: input, arguments: state.arguments, submitted: state.next == .submission)
      if let view = immediateView(state.id, request) {
        showArrival()
        show(view, page: nil, of: state.id, request: request, turn: UUID().uuidString, remembered: remembered)
        retainSelection()
        onResultsChange?()
        return
      }
      target?.busy = true
      let version = generation
      // A submit command's own follow-up updates its page in place, as a conversation's does, so a page
      // followed to its end stays there; any other request is a new page, which starts at its top.
      let followUp = arriving == nil && state.next == .submission && extensionCommand?.manifest.submit == true
      if followUp { details = [] }
      let turn = followUp ? state.turn : UUID().uuidString
      tasks.append(
        Task { [weak self] in
          // A submitted request's first view that carries `input` sets it, once.
          var inputSet = !request.submitted
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            // Each view replaces the last on the same page while the process runs (views over time).
            for try await (view, running) in source(request) {
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
              // Never over what the user typed since sending. In a submit command it runs nothing (the
              // next request waits for Return); in any other it reruns as typing would, so the view
              // always answers what is typed.
              if !inputSet, let text = view.input {
                inputSet = true
                if self.input == request.input, self.input != text { self.input = text }
                guard generation == version else { return }
              }
              // While it runs, Escape stops it and stays on this view; the last one is settled below.
              guard running else { continue }
              command?.busy = true
              command?.live = true
              retainSelection()
              onResultsChange?()
            }
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
          command?.live = false
          retainSelection()
          onResultsChange?()
        })
      onResultsChange?()
      return
    }
    cancelWork()
    isRefreshing = true
    let current = generation
    let request = ProviderRequest(input: input)
    let host = extensions
    appRows = []
    patterns.removeAll()
    let active = configuration.sources(extensions: extensions.ids).filter(\.enabled)
    // Extension items are in memory: matched once per input, not on every batch that recomposes.
    itemRows = active.compactMap { extensions.commands[$0.id] }.map {
      Ranking.Names(provider: $0.id, kind: .item, rows: $0.rootItems(input))
    }
    // The previous file rows stay until the first batch for this input replaces them, so files do not
    // vanish and return on every keystroke; ranking drops those the new input no longer matches.
    let files = files.flatMap { files in
      active.contains { $0.id == files.id } && FileSearch.predicate(for: input) != nil ? files : nil
    }
    if files == nil { fileRows = [] }
    let apps = apps.flatMap { apps in active.contains { $0.id == apps.id } ? apps : nil }
    var appsReady = apps == nil
    // The list is published once the apps answered and, for up to `patternHold`, the pattern
    // extensions whose regex matched, so a calculation lands with the rest of the list rather than
    // after it, without an Ask agent row first. A slower pattern adds its rows when it finishes.
    let matched = Set(
      active.compactMap { extensions.commands[$0.id] }.filter { $0.manifest.matches(input) }.map(\.id))
    var holding = !matched.isEmpty
    let hold = Task { [weak self] in
      guard holding, (try? await Task.sleep(for: Self.patternHold)) != nil, let self, generation == current
      else { return }
      holding = false
      if appsReady { compose() }
    }
    tasks.append(hold)
    if let apps {
      tasks.append(
        Task { [weak self] in
          do {
            let view = try await apps.view(for: request)
            guard let self, !Task.isCancelled, generation == current else { return }
            appRows = view.items
          } catch {
            guard let self, !Task.isCancelled, generation == current else { return }
            providerProblem = "\(apps.id): \(error.localizedDescription)"
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          appsReady = true
          if !holding { compose() }
        })
    }
    for entry in active {
      guard matched.contains(entry.id), let command = extensions.commands[entry.id] else { continue }
      pending.insert(entry.id)
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await host.view(command, request: request)
            guard let self, !Task.isCancelled, generation == current else { return }
            // At the root a pattern result only contributes items; a body is entered like a detail.
            patterns[entry.id] =
              view.body == nil
              ? .items(view.items)
              : .items([
                Row(
                  id: "detail", title: command.manifest.name, subtitle: "Show details",
                  icon: command.manifest.icon,
                  actions: [.run(Address(id: entry.id, input: request.input, link: true))])
              ])
          } catch {
            guard let self, !Task.isCancelled, generation == current else { return }
            patterns[entry.id] = .failed(
              error.localizedDescription.components(separatedBy: "\n").first ?? "")
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          pending.remove(entry.id)
          if holding, pending.isDisjoint(with: matched) {
            holding = false
            hold.cancel()
          }
          if appsReady, !holding { compose() }
        })
    }
    // Each batch of file results replaces the previous one; cancelling the task stops the query.
    if let files {
      pending.insert(files.id)
      tasks.append(
        Task { [weak self] in
          var received = false
          for await rows in files.batches(for: request.input) {
            guard let self, !Task.isCancelled, generation == current else { return }
            received = true
            fileRows = rows
            if appsReady, !holding { compose() }
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          if !received { fileRows = [] }
          pending.remove(files.id)
          if appsReady, !holding { compose() }
        })
    }
    if appsReady, !holding { compose() }
  }
  /// How long the root list waits for pattern extensions whose regex matched: a few frames, more than
  /// the bundled calculator's few milliseconds and short enough that a slow pattern never delays typing.
  static let patternHold = Duration.milliseconds(30)
  /// Waits until no work is left, including work a refresh started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks { await task.value }
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
  private func compose() {
    showArrival()
    isRefreshing = false
    let enabled = Set(configuration.sources(extensions: extensions.ids).filter(\.enabled).map(\.id))
    let commands = extensions.commands.filter { enabled.contains($0.key) }
    let names =
      [
        Ranking.Names(provider: "apps", kind: .app, rows: appRows),
        Ranking.Names(provider: "files", kind: .file, rows: fileRows),
      ] + itemRows
    let ranked = Ranking.compose(
      query: input, names: names, patterns: patterns,
      extensions: commands.mapValues(\.manifest),
      problems: extensions.problems.filter { enabled.contains($0.key) },
      sources: enabled, usage: history.store, now: Date())
    listed = ranked.results
    strongReason = ranked.strongReason
    retainSelection()
    onResultsChange?()
  }
  private func retainSelection() {
    guard actionPanel == nil else { return }
    let rows = results
    if resetSelection { selectionTouched = false }
    if !selectionTouched {
      selection = itemsWait ? nil : rows.first?.id
    } else if let chosen = selection, !rows.contains(where: { $0.id == chosen }) {
      // On a page a target that went away takes the selection with it: Return never moves to a neighbor.
      if page != nil {
        clearSelection()
        resetSelection = false
        return
      }
      if !pending.isEmpty {
        resetSelection = false
        return
      }
      let index = previousRows.firstIndex { $0 == selection } ?? 0
      selection = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
    }
    resetSelection = false
    previousRows = rows.map(\.id)
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
  private var itemsWait: Bool { actionPanel == nil && (agent.active || submits || page != nil) }
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
  /// What a submit sends besides the input: the declared arguments. What a run action set stays out,
  /// or a Delete chosen once would be sent again with every later Return.
  private func filledArguments(of command: CommandState) -> [String: String] {
    let declared = Set(declaredArguments.map(\.name))
    return command.arguments.filter { declared.contains($0.key) }
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
    guard !agent.active, actionPanel == nil else { return [] }
    if command != nil { return extensionCommand?.manifest.arguments ?? [] }
    guard let row = results.first(where: { $0.id == selection }), row.row.id == "command" else { return [] }
    return extensions.commands[row.provider]?.manifest.arguments ?? []
  }
  /// Values filled in at the root for the selected command row; dropped when the selection moves or
  /// the panel is dismissed.
  private var drafted: [String: String] = [:]
  /// The current values by name: the open command's arguments, or the root draft. Unfilled is absent.
  var argumentValues: [String: String] { command?.arguments ?? drafted }
  /// Fills in a declared argument. Inside a command it is an edit like typing: it reruns the command,
  /// or in a submit command waits for Return.
  func setArgument(_ name: String, to value: String) {
    guard declaredArguments.contains(where: { $0.name == name }) else { return }
    let value = value.isEmpty ? nil : value
    guard command != nil else {
      drafted[name] = value
      return
    }
    command?.arguments[name] = value
    resetSelection = true
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
    guard page != nil, actionPanel == nil, turn == pageTurn,
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
    case .detail(let markdown): openDetail(markdown, from: result)
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
    let own = origin.flatMap { commandSource($0) == nil ? nil : $0 }
    let target = address.extensionName == nil ? own : address.targetID
    // A run chosen in Agent History opens as a conversation over the list, which Escape returns to.
    if submitted, target == agentHistory?.id,
      let run = address.arguments?["open"].flatMap({ agentHistory?.run($0) })
    {
      return restore(run)
    }
    switch target {
    case "settings": onSettings()
    case "agent": fill(address.input ?? input)
    case nil: arrive(nil, input: address.input ?? "")
    case let id?:
      guard commandSource(id) != nil else {
        actionProblem = "No extension named \(Address(id: id).extensionName ?? id)"
        return
      }
      let reopened = command?.id == id
      var state = command.flatMap { $0.id == id ? $0 : nil } ?? CommandState(id: id)
      state.arguments = address.arguments ?? [:]
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
  /// Who Return asks: a draft goes to the agent configured now, since settings apply when it is sent.
  var askingName: String { agent.question.isEmpty ? configuration.agent.agent.title : agent.agentName }
  func send(_ text: String? = nil) {
    let text = text ?? input
    guard !agent.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Only a new conversation asked from an extension's command learns what it showed.
    let context =
      agent.active ? (agent.question.isEmpty ? origin?.context : nil) : commandContext(typed: true)
    origin = nil
    actionPanel = nil
    stopArriving()
    cancelWork()
    agent.ask(
      text, context: context?.text, from: context?.name, settings: questionSettings(keeping: agent.reopened))
    questionExpanded = false
    clearSelection()
    input = ""
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
    origin = nil
    actionPanel = nil
    stopArriving()
    cancelWork()
    agent.restore(run, settings: questionSettings(keeping: run.agent))
    questionExpanded = false
    historyExpanded = false
    clearSelection()
    input = ""
  }
  /// Cmd+Return: asks what is typed. With nothing typed it opens an empty conversation about what is on
  /// screen, which Escape leaves for exactly that screen again.
  func askAgent() {
    closeActions()
    guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return send() }
    guard !agent.active else { return }
    // A switch still on its way would end the conversation when it arrives.
    stopArriving()
    origin = Origin(
      context: commandContext(typed: false), input: input, selection: selection, touched: selectionTouched,
      drafted: drafted)
    agent.open(settings: configuration.agent)
    clearSelection()
    input = ""
  }
  /// Where an empty conversation opened by Cmd+Return came from: what its first question tells the
  /// agent, and the screen Escape returns to. The command itself stays open under the conversation.
  private struct Origin {
    let context: (text: String, name: String)?
    let input: String
    let selection: String?
    let touched: Bool
    let drafted: [String: String]
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
      origin = nil
      actionPanel = nil
      stopArriving()
      cancelWork()
      command = nil
      agent.open(settings: configuration.agent)
      clearSelection()
    }
    editInput(text)
  }
  func dismiss() {
    recorder.stop()
    actionPanel = nil
    resetSelection = true
    drafted = [:]
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
    if actionPanel != nil {
      closeActions()
      return true
    }
    // Escape while a command is being entered stays where it was; a way back is already on its way.
    if let arrival = arriving {
      if !arrival.back { stopArriving() }
      return true
    }
    // A detail goes back to where the user was on the page under it.
    if let detail = openDetails.last {
      details = Array(openDetails.dropLast())
      selection = detail.selection
      selectionTouched = detail.touched
      onResultsChange?()
      return true
    }
    if returnsOnEscape, let origin {
      // Cmd+Return's empty conversation goes back to the screen under it as it was: nothing reruns.
      self.origin = nil
      input = origin.input
      agent.reset()
      returnTo(origin.selection, touched: origin.touched, drafted: origin.drafted)
      onResultsChange?()
      return true
    }
    if agent.active {
      // Ending the conversation goes back to what was open under it once that has its content.
      if agent.busy { agent.cancel() } else { arrive(command, input: "", back: true) }
      return true
    }
    if command?.live == true {
      // A view over time stops where it is, as a running answer does; the next Escape goes back.
      cancelWork()
      onResultsChange?()
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
  /// Back on a screen as the user left it: its selection, and the root's draft for a row still there.
  private func returnTo(_ selection: String?, touched: Bool, drafted: [String: String]) {
    self.selection = selection
    selectionTouched = touched
    resetSelection = false
    retainSelection()
    if self.selection == selection { self.drafted = drafted }
  }
  /// What a row's hotkey is bound to: an extension's command row, one of its manifest items (at the root,
  /// or inside the command when the view lists it by the item's id) or a host command. Nil for a row with
  /// no address of its own, such as an app, a file or a fallback.
  func hotkeyTarget(of result: Result) -> HotkeyTarget? {
    if ["settings", "history", "clipboard"].contains(result.provider), result.row.id == "open" {
      return HotkeyTarget(target: result.provider)
    }
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
    var state = CommandState(id: program.id, arguments: request.arguments, next: .rerun)
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
