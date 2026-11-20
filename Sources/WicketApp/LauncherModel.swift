import AppKit
import Observation

/// The launcher's services and what the panel does outside its screens: it composes the sources, the
/// agent's session and the stores, reacts to configuration, owns dictation and hotkey recording, and
/// dispatches the actions the user runs. The screens and moving between them are `navigator`'s.
@MainActor @Observable
final class LauncherModel {
  let navigator: Navigator
  let agent: AgentSession
  let extensions: ExtensionHost
  /// The search at the root.
  let root: RootCommand
  let clipboard: ClipboardHistory?
  let agentHistory: AgentHistory?
  /// The one owner of configuration. The model only reads it.
  let store: ConfigurationStore
  var configuration: Configuration { store.configuration }
  /// Called after every successful or failed configuration load, once the model has reacted.
  @ObservationIgnored var onConfigurationChange: (Configuration?, String?) -> Void = { _, _ in }
  /// The configuration last reacted to.
  @ObservationIgnored private var applied = Configuration()
  private let history: UsageHistory

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
    let directory = CommandDirectory(
      extensions: extensions, hosts: [clipboard as (any HostCommand)?, agentHistory].compactMap { $0 })
    root = RootCommand(apps: apps, files: files, directory: directory, store: store, history: history)
    navigator = Navigator(agent: agent, directory: directory, root: root, store: store, history: history)
    self.history = history
    store.onChange = { [weak self] configuration, problem in
      guard let self else { return }
      if let configuration {
        extensions.settings = configuration.extensions
        if !configuration.voice.enabled { stopVoice(.disabled) }
        clipboard?.configure(enabled: configuration.isEnabled("clipboard", extensions: []))
        var switched: Set<String>?
        if configuration != applied {
          // Of a configuration, only a source switched on or off changes what a command answers.
          let ids = extensions.ids
          switched = Set(configuration.sources(extensions: ids).map(\.id)).filter {
            applied.isEnabled($0, extensions: ids) != configuration.isEnabled($0, extensions: ids)
          }
          applied = configuration
        }
        navigator.applied(switching: switched)
      }
      onConfigurationChange(configuration, problem)
    }
  }

  /// Each source owns its message. Configuration and hotkey problems live in the store, the last
  /// action's in the navigator.
  var installProblem: String?
  var problem: String? {
    store.problem ?? store.hotkeyProblem ?? store.bindingProblem ?? installProblem ?? navigator.actionProblem
  }
  /// The panel shows again: both histories drop what is past their time, and so do the screens.
  func reopen(now: Date = Date()) {
    clipboard?.expire(now: now)
    agentHistory?.expire(now: now)
    navigator.reopen(now: now)
  }

  // MARK: Voice

  private(set) var voice: VoiceInput?
  private let makeTranscriber: () -> any Transcriber
  private let timingURL: URL
  /// The panel makes the key window again when the microphone's consent dialog is done.
  @ObservationIgnored var onVoicePermissionFinished: (() -> Void)?
  func stopVoice(_ reason: VoiceStop) { voice?.stop(reason) }
  func armVoice() { prepareVoice()?.arm() }
  func toggleVoice() { prepareVoice()?.toggle() }
  private func prepareVoice() -> VoiceInput? {
    guard configuration.voice.enabled, agent.takesSpeech else { return nil }
    if voice == nil {
      voice = VoiceInput(
        transcriber: makeTranscriber,
        timingURL: timingURL,
        write: { [weak self] text in
          guard let self, agent.takesSpeech else {
            self?.stopVoice(.busy)
            return
          }
          navigator.dictate(text)
        })
      navigator.voice = voice
    }
    voice?.onPermissionFinished = { [weak self] in self?.onVoicePermissionFinished?() }
    return voice
  }
  func keyPressed(_ action: PaletteKeyAction) -> Bool {
    return voice?.keyPressed(isEscape: action == .dismiss) ?? false
  }

  // MARK: Actions

  /// The one dispatcher for what the user runs, whoever asked: Return, a button, a menu item or a link.
  /// Moving between screens and sending questions go to the navigator. Effects on the panel and the
  /// system (copy, paste, open) are not handled here and return false, except an open or reveal that
  /// `OpenPolicy` refuses: that does nothing but say why. `result` is the row the action came from, if any.
  @discardableResult
  func activate(_ action: RowAction, from result: Result? = nil) -> Bool {
    switch action.kind {
    case .run(let address):
      if let result { navigator.record(result) }
      // Activating a run action is the user's choice; following a link never is.
      navigator.go(address, from: result?.provider, submitted: !address.link)
    case .send(let text): navigator.send(text)
    case .detail(let markdown, let action): navigator.openDetail(markdown, action: action, from: result)
    case .hotkey(let target, record: true):
      recorder.record(target, in: window, store: store) { [weak self] in self?.pauseHotkeys($0) }
    case .hotkey(let target, record: false): store.bind(nil, to: target)
    case .open, .reveal:
      guard let refusal = OpenPolicy.refusal(action) else { return false }
      navigator.actionProblem = refusal
    case .copy, .paste, .clip: return false
    }
    return true
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
        navigator.actionProblem = "This image is no longer in the clipboard history"
        return false
      }
    default: return false
    }
    return true
  }
  /// Records a row's hotkey: Set Hotkey… (`activate`) makes the next shortcut pressed its hotkey, under
  /// the launcher's rules.
  let recorder = ShortcutRecorder()
  /// The panel the recorder listens in, named because Wicket is not the active app while it is key.
  @ObservationIgnored weak var window: NSWindow?
  /// Pauses every global hotkey of Wicket's while a recorder listens (AppDelegate).
  @ObservationIgnored var pauseHotkeys: (Bool) -> Void = { _ in }
  /// Whether Set Hotkey… is recording this row's hotkey.
  func recordsHotkey(of result: Result) -> Bool {
    recorder.target != nil && recorder.target == navigator.hotkeyTarget(of: result)
  }
  func finish() async {
    stopVoice(.quit)
    await voice?.shutdown?.value
    navigator.cancelWork()
    await extensions.shutdown()
    await agent.shutdown()
    await history.finish()
    await clipboard?.finish()
    await agentHistory?.finish()
  }
}
