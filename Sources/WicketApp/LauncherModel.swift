import AppKit
import Observation

/// The extension command screen. Present while a command is open, nil at search.
struct CommandState {
  let id: String
  var arguments: [String] = []
  var view: ProviderView = .list([])
  var problem: String?
  var busy = false
  var turn = UUID().uuidString
}

@MainActor @Observable
final class LauncherModel {
  var input = "" {
    didSet {
      if input != oldValue { resetSelection = true }
      if !agent.active { refresh() }
    }
  }
  let agent: AgentSession
  let extensions: ExtensionHost
  private(set) var results: [Result] = []
  private(set) var isRefreshing = false
  private(set) var command: CommandState? {
    didSet { if command?.id != oldValue?.id { resetSelection = true } }
  }
  private var resetSelection = true
  private var previousRows: [String] = []
  private var selectionTouched = false
  private var pendingExtensions: Set<String> = []
  private(set) var selection: String?
  func select(_ id: String?) {
    selectionTouched = true
    selection = id
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
    guard agent.reopen(now: now) else { return }
    cancelWork()
    command = nil
    input = ""
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
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  private var builtinRows: [String: [Row]] = [:]
  private var patterns: [String: Ranking.Pattern] = [:]
  private var rootErrors: [String: String] = [:]
  /// Why the root list has a strong match, or nil when nothing matches strongly.
  private(set) var strongReason: String?
  private let history: UsageHistory
  var extensionCommand: ExtensionCommand? { command.flatMap { extensions.commands[$0.id] } }

  init(
    providers: [any Provider], history: UsageHistory, folder: URL = FileManager.default.temporaryDirectory,
    transcriber: (() -> any Transcriber)? = nil
  ) {
    makeTranscriber = transcriber
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    timingURL = folder.appending(path: "voice-timing.txt")
    agent = AgentSession(folder: folder)
    extensions = ExtensionHost(folder: folder)
    self.providers = providers
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
    pendingExtensions.removeAll()
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
      guard let extensionCommand = extensions.commands[state.id],
        configuration.isEnabled(state.id, extensions: extensions.ids)
      else {
        command?.problem = "This extension was removed or switched off. Press Esc to go back."
        results = []
        retainSelection()
        onResultsChange?()
        return
      }
      command?.busy = true
      command?.problem = nil
      let version = generation
      let request = ProviderRequest(input: input, arguments: state.arguments)
      let host = extensions
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await host.view(extensionCommand, request: request)
            guard let self, !Task.isCancelled, generation == version else { return }
            command?.turn = UUID().uuidString
            command?.view = view
            if case .list(let rows) = view {
              results = Ranking.order(rows, provider: state.id, query: input)
            } else {
              results = []
            }
          } catch {
            guard let self, !Task.isCancelled, generation == version else { return }
            command?.problem = report(extensionCommand, request: request, error: error)
            results = []
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
    rootErrors.removeAll()
    let active = configuration.sources(extensions: extensions.ids).filter(\.enabled)
    let builtins = active.compactMap { entry in providers.first { $0.id == entry.id } }
    var remaining = builtins.count
    var builtinsReady = remaining == 0
    for provider in builtins {
      tasks.append(
        Task { [weak self] in
          do {
            let view = try await provider.view(for: request)
            guard let self, !Task.isCancelled, generation == current else { return }
            if case .list(let rows) = view { builtinRows[provider.id] = rows }
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
      pendingExtensions.insert(entry.id)
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await host.view(command, request: request)
            guard let self, !Task.isCancelled, generation == current else { return }
            switch view {
            case .list(let rows): patterns[entry.id] = .rows(rows)
            case .detail:
              patterns[entry.id] = .rows([
                Row(
                  id: "detail", title: command.manifest.name, subtitle: "Show details",
                  icon: command.manifest.icon, actions: [])
              ])
            }
          } catch {
            guard let self, !Task.isCancelled, generation == current else { return }
            rootErrors[entry.id] = report(command, request: request, error: error)
            patterns[entry.id] = .failed(error.localizedDescription.components(separatedBy: "\n").first ?? "")
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          pendingExtensions.remove(entry.id)
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
      query: input, math: builtinRows["math"] ?? [], apps: builtinRows["apps"] ?? [], patterns: patterns,
      extensions: extensions.commands.filter { enabled.contains($0.key) }.mapValues(\.manifest),
      problems: extensions.problems.filter { enabled.contains($0.key) },
      usage: history.store, now: Date())
    results = ranked.results
    strongReason = ranked.strongReason
    retainSelection()
    onResultsChange?()
  }
  private func retainSelection() {
    let rows = results
    if resetSelection { selectionTouched = false }
    if !selectionTouched {
      selection = rows.first?.id
    } else if !rows.contains(where: { $0.id == selection }) {
      if !pendingExtensions.isEmpty {
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
  var detailBody: String? {
    guard let command, command.problem == nil, case .detail(let body, _, _) = command.view else { return nil }
    return body
  }
  var metadata: [ProviderView.Metadata] {
    if case .detail(_, let metadata, _)? = command?.view { return metadata }
    return []
  }
  var selected: Result? {
    if let command, case .detail(_, _, let actions) = command.view, command.problem == nil {
      return Result(
        provider: command.id,
        row: Row(id: "detail", title: extensionCommand?.manifest.name ?? "Details", actions: actions))
    }
    return results.first { $0.id == selection }
  }
  func move(_ delta: Int) {
    guard !agent.active, !results.isEmpty else { return }
    let rows = results
    let current = rows.firstIndex { $0.id == selection } ?? 0
    select(rows[min(max(current + delta, 0), rows.count - 1)].id)
  }
  func enterSelected() -> Bool {
    if selected?.provider == "settings" {
      onSettings()
      return true
    }
    guard command == nil, let result = selected, let extensionCommand = extensions.commands[result.provider],
      result.row.actions.isEmpty
    else { return false }
    let oldInput = input
    record(result)
    cancelWork()
    command = CommandState(id: extensionCommand.id)
    results = []
    if let error = rootErrors[extensionCommand.id], result.row.id == "error" {
      command?.problem = error
      onResultsChange?()
    } else {
      input = result.row.id == "command" ? "" : oldInput
    }
    return true
  }
  func rerun(_ provider: String, arguments: [String]) {
    cancelWork()
    if command?.id == provider {
      command?.arguments = arguments
    } else {
      command = CommandState(id: provider, arguments: arguments)
    }
    refresh()
  }
  func ask(_ text: String? = nil) {
    let text = text ?? input
    guard !agent.busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    cancelWork()
    agent.ask(text, settings: configuration.agent)
    questionExpanded = false
    input = ""
  }
  func dismiss() {
    resetSelection = true
    stopVoice()
    agent.hidden()
    if agent.active { return }
    cancelWork()
    command = nil
    input = ""
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
  }
}
