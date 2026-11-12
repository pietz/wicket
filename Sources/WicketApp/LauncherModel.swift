import AppKit
import Observation

/// The command screen: an extension's, or the clipboard history's. Nil at search.
struct CommandState {
  let id: String
  var arguments: [String: String] = [:]
  /// What the next request answers. Going to an address runs it even in a submit command, and the
  /// user's activation makes it chosen; every later request is a rerun.
  var next = Cause.address
  enum Cause { case rerun, address, choice }
  var view = ProviderView()
  var problem: String?
  var busy = false
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
      if !agent.active, arriving == nil { refresh() }
    }
  }
  let agent: AgentSession
  let extensions: ExtensionHost
  /// The list at search and inside a command.
  private var listed: [Result] = [] { didSet { sizeList() } }
  /// The rows the list card is sized for: more show at once, fewer only after 300 ms, so a late batch
  /// such as file results does not make the panel shrink and grow again while typing. A list for
  /// another screen is sized at once: the hold is for results of one screen arriving late.
  private(set) var sizedRows = 1
  private var shrinking: Task<Void, Never>?
  private var sizedFor: String?
  private func sizeList(now: Bool = false) {
    let count = max(1, min(listed.count, 8))
    let screen = command?.id
    shrinking?.cancel()
    shrinking = nil
    guard count < sizedRows, !now, screen == sizedFor else {
      sizedFor = screen
      sizedRows = count
      return
    }
    shrinking = Task { [weak self] in
      guard (try? await Task.sleep(for: .milliseconds(300))) != nil, let self else { return }
      shrinking = nil
      sizedRows = max(1, min(listed.count, 8))
      onResultsChange?()
    }
  }
  /// The rows under the open page: the conversation's items while there is one, else the list.
  var results: [Result] {
    agent.active ? agent.view.items.map { Result(provider: "answer", row: $0) } : listed
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
  /// Prepares an arriving page before it is shown: the controller renders and measures its body, so the
  /// card's height is known when the page appears. Arguments are the body, its turn and whether it is
  /// capped (no items below it).
  var preparePage: ((String, String, Bool) async -> Void)?
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
    }
  }
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
    store.problem ?? store.hotkeyProblem ?? installProblem ?? actionProblem ?? providerProblem
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
  /// The one owner of configuration. The model only reads it.
  let store: ConfigurationStore
  var configuration: Configuration { store.configuration }
  /// Called after every successful or failed configuration load, once the model has reacted.
  var onConfigurationChange: (Configuration?, String?) -> Void = { _, _ in }
  private(set) var voice: VoiceInput?
  private let makeTranscriber: (() -> any Transcriber)?
  private let timingURL: URL
  var takesSpeech: Bool { !agent.busy && agent.permissions.isEmpty }
  func stopVoice() { voice?.stop() }
  func armVoice() { prepareVoice()?.arm() }
  func toggleVoice() { prepareVoice()?.toggle() }
  private func prepareVoice() -> VoiceInput? {
    guard configuration.voice.enabled, takesSpeech else { return nil }
    if voice == nil {
      voice = VoiceInput(
        transcriber: { [weak self] in
          self?.makeTranscriber?() ?? AppleTranscriber(microphoneUID: self?.configuration.voice.microphone)
        },
        timingURL: timingURL,
        write: { [weak self] text in
          guard let self, takesSpeech else {
            self?.stopVoice()
            return
          }
          input = text
        })
    }
    voice?.onPermissionFinished = { [weak self] in self?.onVoicePermissionFinished?() }
    return voice
  }
  /// Used by the native field, including paste and IME edits that arrive without a shortcut.
  func editInput(_ text: String) {
    stopVoice()
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
  var onResultsChange: (() -> Void)?
  private let providers: [any Provider]
  private let files: FilesProvider?
  private var fileRows: [Row] = []
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  private var builtinRows: [String: [Row]] = [:]
  private var itemRows: [Ranking.Names] = []
  private var patterns: [String: Ranking.Pattern] = [:]
  /// Why the root list has a strong match, or nil when nothing matches strongly.
  private(set) var strongReason: String?
  private let history: UsageHistory
  var extensionCommand: ExtensionCommand? { command.flatMap { extensions.commands[$0.id] } }
  let clipboard: ClipboardHistory?
  /// What answers a command's requests: an extension's command through the host, or a built-in provider
  /// (the clipboard history). Nil when there is no such command.
  private func commandSource(_ id: String) -> (@MainActor (ProviderRequest) async throws -> ProviderView)? {
    if let command = extensions.commands[id] {
      let host = extensions
      return { try await host.view(command, request: $0) }
    }
    guard let clipboard, clipboard.id == id else { return nil }
    return { clipboard.view(for: $0) }
  }
  /// What a command answers without waiting for anything: an extension's manifest items, or the
  /// clipboard history. Nil when it runs a process.
  private func immediateView(_ id: String, _ request: ProviderRequest) -> ProviderView? {
    if let command = extensions.commands[id] {
      return command.manifest.command == nil ? ProviderView(items: command.ownItems(request.input)) : nil
    }
    guard let clipboard, clipboard.id == id else { return nil }
    return clipboard.view(for: request)
  }
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? { command.flatMap { name(of: $0.id) } }
  private func name(of id: String) -> String? {
    extensions.commands[id]?.manifest.name ?? (id == clipboard?.id ? ClipboardHistory.title : nil)
  }

  init(
    providers: [any Provider], files: FilesProvider? = nil, clipboard: ClipboardHistory? = nil,
    history: UsageHistory, folder: URL = FileManager.default.temporaryDirectory,
    transcriber: (() -> any Transcriber)? = nil
  ) {
    self.clipboard = clipboard
    makeTranscriber = transcriber
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    timingURL = folder.appending(path: "voice-timing.txt")
    agent = AgentSession(folder: folder)
    extensions = ExtensionHost(folder: folder)
    self.providers = providers
    self.files = files
    self.history = history
    let inputChanged: () -> Void = { [weak self] in
      guard let self else { return }
      if !takesSpeech { stopVoice() }
      onResultsChange?()
    }
    agent.onChange = inputChanged
    extensions.onCatalogChange = { [weak self] in self?.sourcesChanged($0) }
    store.onChange = { [weak self] configuration, problem in
      guard let self else { return }
      if let configuration {
        if !configuration.voice.enabled { stopVoice() }
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
  func refresh() {
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
      guard let source, configuration.isEnabled(state.id, extensions: extensions.ids) else {
        target?.problem =
          source == nil
          ? "This extension was removed. Press Esc to go back."
          : "\(name(of: state.id) ?? state.id) is switched off. Switch it on in Settings, Sources, or press Esc to go back."
        showArrival()
        listed = []
        retainSelection()
        onResultsChange?()
        return
      }
      target?.problem = nil
      let request = ProviderRequest(input: input, arguments: state.arguments, chosen: state.next == .choice)
      if let view = immediateView(state.id, request) {
        showArrival()
        show(view, of: state.id, turn: UUID().uuidString)
        retainSelection()
        onResultsChange?()
        return
      }
      target?.busy = true
      let version = generation
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await source(request)
            guard let self, !Task.isCancelled, generation == version else { return }
            let turn = UUID().uuidString
            if arriving != nil, let body = view.body, let preparePage {
              await preparePage(body, turn, view.items.isEmpty)
              guard !Task.isCancelled, generation == version else { return }
            }
            showArrival()
            show(view, of: state.id, turn: turn)
          } catch {
            guard let self, !Task.isCancelled, generation == version else { return }
            showArrival()
            command?.problem =
              extensionCommand.map { report($0, request: request, error: error) }
              ?? error.localizedDescription
            listed = []
          }
          guard let self, generation == version else { return }
          command?.busy = false
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
    builtinRows.removeAll()
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
    let builtins = active.compactMap { entry in providers.first { $0.id == entry.id } }
    var remaining = builtins.count
    var builtinsReady = remaining == 0
    for provider in builtins {
      tasks.append(
        Task { [weak self] in
          do {
            let view = try await provider.view(for: request)
            guard let self, !Task.isCancelled, generation == current else { return }
            builtinRows[provider.id] = view.items
          } catch {
            guard let self, !Task.isCancelled, generation == current else { return }
            providerProblem = "\(provider.id): \(error.localizedDescription)"
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          remaining -= 1
          if remaining == 0 {
            builtinsReady = true
            compose()
          }
        })
    }
    for entry in active {
      guard let command = extensions.commands[entry.id], command.manifest.matches(input) else { continue }
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
          if builtinsReady { compose() }
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
            if builtinsReady { compose() }
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          if !received { fileRows = [] }
          pending.remove(files.id)
          if builtinsReady { compose() }
        })
    }
    if builtinsReady { compose() }
  }
  /// Waits until no work is left, including work a refresh started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks { await task.value }
    } while seen != generation
  }
  /// A command's view, ordered by what is typed.
  private func show(_ view: ProviderView, of id: String, turn: String) {
    command?.turn = turn
    command?.view = view
    command?.busy = false
    listed = Ranking.order(view.items, provider: id, query: input)
  }
  private func compose() {
    showArrival()
    isRefreshing = false
    let enabled = Set(configuration.sources(extensions: extensions.ids).filter(\.enabled).map(\.id))
    let commands = extensions.commands.filter { enabled.contains($0.key) }
    let names =
      [
        Ranking.Names(provider: "apps", kind: .app, rows: builtinRows["apps"] ?? []),
        Ranking.Names(provider: "files", kind: .file, rows: fileRows),
      ] + itemRows
    let ranked = Ranking.compose(
      query: input, math: builtinRows["math"] ?? [], names: names, patterns: patterns,
      extensions: commands.mapValues(\.manifest),
      problems: extensions.problems.filter { enabled.contains($0.key) },
      sources: enabled, usage: history.store, now: Date())
    listed = ranked.results
    strongReason = ranked.strongReason
    retainSelection()
    onResultsChange?()
  }
  private func retainSelection() {
    let rows = results
    if resetSelection { selectionTouched = false }
    if !selectionTouched {
      selection = itemsWait ? nil : rows.first?.id
    } else if let chosen = selection, !rows.contains(where: { $0.id == chosen }) {
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
  /// The open command's Markdown body, shown above its items.
  var body: String? {
    guard let command, command.problem == nil else { return nil }
    return command.view.body
  }
  /// The view's own actions, in the header beside the body.
  var viewActions: [RowAction] { body == nil ? [] : command?.view.actions ?? [] }
  /// Whether the input has the first say, so items wait for an arrow key and typing leaves them: in a
  /// conversation Return sends the follow-up, in a submit command it sends the request, and on a page
  /// it runs the view's actions.
  private var itemsWait: Bool { agent.active || submits || body != nil }
  /// The open command runs on Return only (`submit` in its manifest).
  var submits: Bool { extensionCommand?.manifest.submit == true }
  /// Return runs the selected item. With none selected, a submit command sends what is typed and
  /// filled in as a chosen request, a page runs the view's own actions, and a conversation sends the
  /// follow-up.
  var selected: Result? {
    if let row = results.first(where: { $0.id == selection }) { return row }
    guard !agent.active, let command else { return nil }
    if submits {
      return Result(
        provider: command.id,
        row: Row(
          id: "submit", title: commandName ?? "Run",
          actions: [.run(Address(input: input, arguments: filledArguments(of: command)))]))
    }
    guard body != nil else { return nil }
    return Result(
      provider: command.id,
      row: Row(id: "detail", title: commandName ?? "Details", actions: viewActions))
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
    guard !agent.active else { return [] }
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
      go(address, from: result?.provider, chosen: !address.link)
    case .send(let text): send(text)
    case .open, .reveal:
      guard let refusal = OpenPolicy.refusal(action) else { return false }
      actionProblem = refusal
    case .copy, .paste: return false
    }
    return true
  }
  /// Return on the selected row, or the follow-up of a conversation.
  @discardableResult func activateReturn() -> Bool {
    returnAction.map { activate($0, from: selected) } ?? false
  }
  /// Takes the user to an address. `origin` is the provider of the row it came from, which an address
  /// that omits its target names; any provider that is not a command means the root. An empty target
  /// is always the root. `chosen` marks the user activating a run action, which the first request says.
  func go(_ address: Address, from origin: String? = nil, chosen: Bool = false) {
    let own = origin.flatMap { commandSource($0) == nil ? nil : $0 }
    switch address.extensionName == nil ? own : address.targetID {
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
      state.next = chosen ? .choice : .address
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
    stopArriving()
    cancelWork()
    agent.ask(text, settings: configuration.agent)
    questionExpanded = false
    clearSelection()
    input = ""
  }
  /// The `agent` action: the text becomes the input and nothing is sent. In a conversation the next
  /// Return is the follow-up. Anywhere else an open command is left and an empty conversation opens
  /// with the text as its unsent first question.
  func fill(_ text: String) {
    if !agent.active {
      stopArriving()
      cancelWork()
      command = nil
      agent.open(settings: configuration.agent)
      clearSelection()
    }
    editInput(text)
  }
  func dismiss() {
    resetSelection = true
    drafted = [:]
    focusTarget = nil
    stopVoice()
    agent.hidden()
    stopArriving()
    if agent.active { return }
    cancelWork()
    command = nil
    input = ""
    sizeList(now: true)
  }
  func escape() -> Bool {
    focusTarget = nil
    // Escape while a command is being entered stays where it was; a way back is already on its way.
    if let arrival = arriving {
      if !arrival.back { stopArriving() }
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
  private func report(_ command: ExtensionCommand, request: ProviderRequest, error: any Error) -> String {
    "Extension: \(command.folder.path)\nCommand: \(command.manifest.command ?? [])\nRequest: \(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self))\n\n\(error.localizedDescription)"
  }
  /// Only picks that root search can learn from: not inside a chosen command, and not computed
  /// answers or fallbacks.
  func record(_ result: Result, input: String? = nil) {
    guard command == nil, result.provider != "math", result.row.id != "fallback" else { return }
    history.record(result.id, input: input ?? self.input)
  }
  func finish() async {
    stopVoice()
    await voice?.shutdown?.value
    cancelWork()
    await extensions.shutdown()
    await agent.shutdown()
    await history.finish()
    await clipboard?.finish()
  }
}
