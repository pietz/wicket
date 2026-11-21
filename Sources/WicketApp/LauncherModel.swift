import Foundation
import Observation

/// The launcher's services: it composes the sources, the agent's session and the stores, applies a
/// configuration to them, and decides what a hotkey does. The screens and moving between them are
/// `navigator`'s; dictation, recording a hotkey and the effects on the system are the panel's
/// (`PaletteController`).
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
  /// The configuration last reacted to.
  @ObservationIgnored private var applied = Configuration()
  private let history: UsageHistory

  init(
    apps: (any Provider)? = nil, files: FilesProvider? = nil, clipboard: ClipboardHistory? = nil,
    agentHistory: AgentHistory? = nil, history: UsageHistory,
    folder: URL = FileManager.default.temporaryDirectory, bundled: URL? = ExtensionHost.bundledFolder
  ) {
    self.clipboard = clipboard
    self.agentHistory = agentHistory
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    agent = AgentSession(folder: folder)
    agent.history = agentHistory
    extensions = ExtensionHost(folder: folder, bundled: bundled)
    let directory = CommandDirectory(
      extensions: extensions, hosts: [clipboard as (any HostCommand)?, agentHistory].compactMap { $0 },
      store: store)
    root = RootCommand(apps: apps, files: files, directory: directory, store: store, history: history)
    navigator = Navigator(agent: agent, directory: directory, root: root, store: store, history: history)
    self.history = history
    // Tests and headless runs react with the services alone; the app reacts in its own order, these
    // first (`AppDelegate`).
    store.onChange = { [weak self] configuration, _ in self?.apply(configuration) }
  }
  /// A configuration was loaded: the extensions' settings, the clipboard and the sources it switched on
  /// or off follow it. Nil when the file could not be read: the store's stand-in then, which is the last
  /// good configuration, or before one loaded the defaults without extensions.
  func apply(_ configuration: Configuration?) {
    let configuration = configuration ?? store.configuration
    extensions.settings = configuration.extensions
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

  // MARK: Hotkeys

  /// A hotkey bound to `target` was pressed: as Return on what it names, with no usage recorded. A manifest
  /// item's first action is done: a hidden run (`Navigator.runHidden`), or a copy, paste, open or reveal,
  /// without the panel unless it has to say why it could not. Anything else shows the panel on its
  /// address (`Navigator.open`): a command, a host command, or an item's `run` action.
  func press(_ target: HotkeyTarget) {
    let owner = target.target.flatMap { extensions.commands[$0] }
    let item = target.item.flatMap { id in owner?.manifest.items?.first { $0.id == id } }
    // A switched-off extension's items run nothing: its address shows that it is off.
    guard let owner, let action = item?.actions.first,
      configuration.isEnabled(owner.id, extensions: extensions.ids)
    else { return navigator.open(target.address, pressed: target) }
    switch action.kind {
    case .run(let address) where address.hidden: navigator.runHidden(address, from: owner.id)
    case .run(let address): navigator.open(address, from: owner.id, submitted: !address.link, pressed: target)
    case .copy, .paste, .open, .reveal: navigator.perform(action)
    case .send, .detail, .clip, .hotkey: navigator.open(target.address, pressed: target)
    }
  }
  func finish() async {
    navigator.finish()
    await extensions.shutdown()
    await agent.shutdown()
    await history.finish()
    await clipboard?.finish()
    await agentHistory?.finish()
  }
}
