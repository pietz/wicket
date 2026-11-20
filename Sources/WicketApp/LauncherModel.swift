import Foundation
import Observation

/// The launcher's services: it composes the sources, the agent's session and the stores, applies a
/// configuration to them, and runs what a hotkey names. The screens and moving between them are
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
      extensions: extensions, hosts: [clipboard as (any HostCommand)?, agentHistory].compactMap { $0 })
    root = RootCommand(apps: apps, files: files, directory: directory, store: store, history: history)
    navigator = Navigator(agent: agent, directory: directory, root: root, store: store, history: history)
    self.history = history
    // Tests and headless runs react with the services alone; the app reacts in its own order, these
    // first (`AppDelegate`).
    store.onChange = { [weak self] configuration, _ in self?.apply(configuration) }
  }
  /// A configuration was loaded: the extensions' settings, the clipboard and the sources it switched on
  /// or off follow it. Nil when the file could not be read, which changes nothing.
  func apply(_ configuration: Configuration?) {
    guard let configuration else { return }
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

  /// A hotkey bound to `target` was pressed. A manifest item whose first action runs an extension's program
  /// runs it now with a submitted request, as Return on the item would, with the panel hidden; a view that
  /// says it is done keeps it hidden, and any other view or a failure calls `show` and shows the command
  /// with it, such as why no window moved. Anything else shows the panel on the address: a command, a
  /// host command, or an item whose action opens a view. Nothing is recorded as usage. `prepare` renders
  /// a view's page before the panel shows it.
  func press(
    _ target: HotkeyTarget, prepare: ((Page, String) async -> PageMeasurement)? = nil, show: () -> Void
  ) async {
    let owner = target.target.flatMap { extensions.commands[$0] }
    let item = target.item.flatMap { id in owner?.manifest.items?.first { $0.id == id } }
    // A switched-off extension's items run nothing: its address shows that it is off.
    guard let owner, let item, case .run(let address)? = item.actions.first?.kind,
      configuration.isEnabled(owner.id, extensions: extensions.ids)
    else {
      show()
      return navigator.go(target.address)
    }
    let id = address.extensionName == nil ? owner.id : address.targetID
    guard !address.link, let id, let program = extensions.commands[id], program.manifest.command != nil,
      configuration.isEnabled(id, extensions: extensions.ids)
    else {
      show()
      return navigator.go(address, from: owner.id, submitted: !address.link)
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
      return navigator.adopt(program, request: request, problem: program.report(request, error: error))
    }
    guard !view.close else { return }
    let turn = UUID().uuidString
    let page = view.body.map { Page(body: $0, items: view.items, runs: true) }
    var measured: PageHeight?
    if let page, let prepare, case .measured(let height) = await prepare(page, turn) { measured = height }
    show()
    navigator.adopt(program, request: request, view: view, page: page, turn: turn, measured: measured)
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
