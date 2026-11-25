import Foundation
import Observation

/// The launcher's services: it composes the sources, the agent's session and the stores, applies a
/// configuration to them, and decides what a hotkey does. The screens and moving between them are
/// `navigator`'s; dictation, recording a hotkey and the effects on the system are the panel's
/// (`PaletteController`).
@MainActor @Observable
final class LauncherModel {
  let navigator: Navigator
  private let directory: CommandDirectory
  let agent: AgentSession
  let extensions: ExtensionHost
  let runtime: RuntimeRecorder?
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
  private let availableUpdate: () -> String?
  let checkForUpdates: () -> Void

  init(
    apps: AppSearch? = nil, files: FilesProvider? = nil, clipboard: ClipboardHistory? = nil,
    agentHistory: AgentHistory? = nil, history: UsageHistory,
    folder: URL = FileManager.default.temporaryDirectory, bundled: URL? = ExtensionHost.bundledFolder,
    extensionDataDirectory: URL? = nil, availableUpdate: @escaping () -> String? = { nil },
    checkForUpdates: @escaping () -> Void = {}, runtime: RuntimeRecorder? = nil
  ) {
    self.clipboard = clipboard
    self.agentHistory = agentHistory
    self.availableUpdate = availableUpdate
    self.checkForUpdates = checkForUpdates
    self.runtime = runtime
    store = ConfigurationStore(url: folder.appending(path: "config.json"))
    agent = AgentSession(folder: folder)
    agent.history = agentHistory
    extensions = ExtensionHost(
      folder: folder, bundled: bundled, dataDirectory: extensionDataDirectory, runtime: runtime)
    directory = CommandDirectory(
      extensions: extensions, hosts: [clipboard as (any HostCommand)?, agentHistory].compactMap { $0 },
      store: store)
    root = RootCommand(apps: apps, files: files, directory: directory, store: store, history: history)
    navigator = Navigator(agent: agent, directory: directory, root: root, store: store, history: history)
    self.history = history
    navigator.footerProblem = { [weak self] in self?.problem }
    extensions.migrateLists = { [weak self] commands, locations in
      guard let self else { return .init() }
      let result = ListMigration.run(
        commands, locations: locations, root: folder.appending(path: "extensions"), store: store)
      if result.count > 0 { navigator.personalItemsMigrated(result.count) }
      return result
    }
    // Tests and headless runs react with the services alone; the app reacts in its own order, these
    // first (`AppDelegate`).
    store.onChange = { [weak self] configuration in self?.apply(configuration) }
  }
  /// A configuration was loaded (`ConfigurationStore.onChange`): the extensions' settings, the clipboard
  /// and the sources it switched on or off follow it.
  func apply(_ configuration: Configuration) {
    let updated = extensions.applySettings(configuration.extensions)
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
    navigator.applied(switching: updated.isEmpty ? switched : updated.union(switched ?? []))
    if store.problem == nil { extensions.configChanged() }
  }

  /// Each source owns its message. Configuration and hotkey problems live in the store, the last
  /// action's in the navigator.
  var installProblem: String?
  var problem: String? {
    store.problem ?? store.rejection?.problem ?? store.hotkeyProblem ?? store.bindingProblem ?? installProblem
      ?? navigator.actionProblem
  }
  /// The panel shows again: both histories drop what is past their time, and so do the screens.
  func reopen(now: Date = Date()) {
    runtime?.refreshPermissions(extensions.permissions)
    clipboard?.expire(now: now)
    agentHistory?.expire(now: now)
    navigator.reopen(now: now, availableUpdate: availableUpdate())
  }

  // MARK: Hotkeys

  /// A hotkey bound to `target` was pressed: as Return on what it names, with no usage recorded. A static
  /// item's first action is done: a hidden run (`Navigator.runHidden`), or a copy, paste, open or reveal,
  /// without the panel unless it has to say why it could not. Anything else shows the panel on its
  /// address (`Navigator.open`): a command, a host command, or an item's `run` action. Pressed before the
  /// first extension scan, it waits for it, so the item is found.
  func press(_ target: HotkeyTarget) {
    guard extensions.scanned else {
      Task { [weak self] in
        await self?.extensions.firstScan()
        self?.press(target)
      }
      return
    }
    switch directory.resolveHotkey(target).delivery {
    case .open(let address): navigator.open(address, pressed: target)
    case .problem(let message): navigator.reportActionProblem(message)
    case .item(let result, let action):
      switch navigator.applyingDraft(to: action, for: target).kind {
      case .run(let address) where address.hidden:
        navigator.runHidden(address, from: result.provider, pressed: target)
      case .run(let address):
        navigator.open(address, from: result.provider, submitted: !address.link, pressed: target)
      case .copy, .paste, .open, .reveal: navigator.perform(action)
      case .save: navigator.activate(action, from: result)
      default: break
      }
    }
  }
  func finish() async {
    navigator.finish()
    await extensions.shutdown()
    await agent.shutdown()
    await history.finish()
    await clipboard?.finish()
    await agentHistory?.finish()
    await runtime?.finish()
  }
}
