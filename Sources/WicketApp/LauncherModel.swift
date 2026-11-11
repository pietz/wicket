import AppKit
import Observation

/// The command screen: an extension's, or the clipboard history's. Nil at search.
struct CommandState {
  let id: String
  var arguments: [String] = []
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
      if !agent.active { refresh() }
    }
  }
  let agent: AgentSession
  let extensions: ExtensionHost
  /// The list at search and inside a command.
  private var listed: [Result] = [] { didSet { sizeList() } }
  /// The rows the list card is sized for: more show at once, fewer only after 300 ms, so a late batch
  /// such as file results does not make the panel shrink and grow again while typing.
  private(set) var sizedRows = 1
  private var shrinking: Task<Void, Never>?
  private func sizeList(now: Bool = false) {
    let count = max(1, min(listed.count, 8))
    shrinking?.cancel()
    shrinking = nil
    guard count < sizedRows, !now else {
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
  private var resetSelection = true
  private var previousRows: [String] = []
  private var selectionTouched = false
  /// Sources whose results for this input may still arrive: running pattern extensions and file search.
  private var pending: Set<String> = []
  private(set) var selection: String?
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
  var conversationHeaderHeight: CGFloat = 58 {
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
    return { await clipboard.view(for: $0) }
  }
  /// The open command's name, for the input placeholder and the footer.
  var commandName: String? {
    extensionCommand?.manifest.name ?? (command?.id == clipboard?.id ? ClipboardHistory.title : nil)
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
    extensions.onCatalogChange = { [weak self] in self?.catalogChanged() }
    store.onChange = { [weak self] configuration, problem in
      guard let self else { return }
      if let configuration {
        if !configuration.voice.enabled { stopVoice() }
        clipboard?.configure(enabled: configuration.isEnabled("clipboard", extensions: []))
        onResultsChange?()
      }
      onConfigurationChange(configuration, problem)
    }
  }
  private func cancelWork() {
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    isRefreshing = false
    command?.busy = false
    pending.removeAll()
  }
  func catalogChanged() {
    // A changed/deleted command cancels its in-flight invocation too.
    refresh()
  }
  func refresh() {
    guard !agent.active else { return }
    cancelWork()
    let speaking = voice?.active == true
    if let state = command {
      let source = commandSource(state.id)
      guard let source, configuration.isEnabled(state.id, extensions: extensions.ids) else {
        command?.problem =
          source == nil
          ? "This extension was removed. Press Esc to go back."
          : "\(commandName ?? state.id) is switched off. Switch it on in Settings, Sources, or press Esc to go back."
        listed = []
        retainSelection()
        onResultsChange?()
        return
      }
      command?.busy = true
      command?.problem = nil
      let version = generation
      let request = ProviderRequest(input: input, arguments: state.arguments)
      let extensionCommand = extensionCommand
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await source(request)
            guard let self, !Task.isCancelled, generation == version else { return }
            command?.turn = UUID().uuidString
            command?.view = view
            listed = Ranking.order(view.items, provider: state.id, query: input)
          } catch {
            guard let self, !Task.isCancelled, generation == version else { return }
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
    isRefreshing = true
    let current = generation
    let request = ProviderRequest(input: input)
    let host = extensions
    builtinRows.removeAll()
    patterns.removeAll()
    let active = configuration.sources(extensions: extensions.ids).filter(\.enabled)
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
                  icon: command.manifest.icon, actions: [.run(Address(id: entry.id, input: request.input))])
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
  private func compose() {
    isRefreshing = false
    let enabled = Set(configuration.sources(extensions: extensions.ids).filter(\.enabled).map(\.id))
    let ranked = Ranking.compose(
      query: input, math: builtinRows["math"] ?? [], apps: builtinRows["apps"] ?? [], files: fileRows,
      patterns: patterns,
      extensions: extensions.commands.filter { enabled.contains($0.key) }.mapValues(\.manifest),
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
      // A page has the first say: Return runs its actions until an arrow key enters the items.
      selection = body == nil ? rows.first?.id : nil
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
  /// Return runs the selected item. With none selected, which is how a page starts, it runs the
  /// view's own actions inside a command, and in a conversation it sends the follow-up.
  var selected: Result? {
    if let row = results.first(where: { $0.id == selection }) { return row }
    guard !agent.active, let command, body != nil else { return nil }
    return Result(
      provider: command.id,
      row: Row(id: "detail", title: commandName ?? "Details", actions: viewActions))
  }
  /// What Return does: the selected row's first action, or in a conversation with nothing selected,
  /// sending the follow-up.
  var returnAction: RowAction? {
    selected?.row.actions.first ?? (agent.active ? .send(input) : nil)
  }
  /// Arrow keys: the first press enters the items of a page, and up from the first leaves them.
  func move(_ delta: Int) {
    let rows = results
    guard !rows.isEmpty else { return }
    guard let current = rows.firstIndex(where: { $0.id == selection }) else {
      select(rows[0].id)
      return
    }
    if current == 0, delta < 0, body != nil || agent.active {
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
    switch action {
    case .run(let address):
      if let result { record(result) }
      go(address, from: result?.provider)
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
  /// is always the root.
  func go(_ address: Address, from origin: String? = nil) {
    let own = origin.flatMap { commandSource($0) == nil ? nil : $0 }
    switch address.extensionName == nil ? own : address.targetID {
    case "settings": onSettings()
    case "agent": fill(address.input ?? input)
    case nil:
      takeOver()
      command = nil
      input = address.input ?? ""
    case let id?:
      guard commandSource(id) != nil else {
        actionProblem = "No extension named \(Address(id: id).extensionName ?? id)"
        return
      }
      takeOver()
      let reopened = command?.id == id
      if !reopened {
        command = CommandState(id: id)
        listed = []
      }
      command?.arguments = address.arguments ?? []
      // Typing replaces the input, and an address without one keeps what is typed in the same command.
      input = address.input ?? (reopened ? input : "")
    }
  }
  /// A conversation ends and the running work stops when an address takes over.
  private func takeOver() {
    if agent.active { agent.reset() }
    cancelWork()
  }
  /// Who Return asks: a draft goes to the agent configured now, since settings apply when it is sent.
  var askingName: String { agent.question.isEmpty ? configuration.agent.agent.title : agent.agentName }
  func send(_ text: String? = nil) {
    let text = text ?? input
    guard !agent.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
      cancelWork()
      command = nil
      agent.open(settings: configuration.agent)
      clearSelection()
    }
    editInput(text)
  }
  func dismiss() {
    resetSelection = true
    stopVoice()
    agent.hidden()
    if agent.active { return }
    cancelWork()
    command = nil
    input = ""
    sizeList(now: true)
  }
  func escape() -> Bool {
    if agent.active {
      if agent.busy {
        agent.cancel()
      } else {
        agent.reset()
        input = ""
      }
      return true
    }
    if command != nil {
      cancelWork()
      command = nil
      input = ""
      return true
    }
    if !input.isEmpty {
      input = ""
      return true
    }
    return false
  }
  private func report(_ command: ExtensionCommand, request: ProviderRequest, error: any Error) -> String {
    "Extension: \(command.folder.path)\nCommand: \(command.manifest.command)\nRequest: \(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self))\n\n\(error.localizedDescription)"
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
