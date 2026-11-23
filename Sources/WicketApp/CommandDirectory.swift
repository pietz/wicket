import Foundation

/// A command the host answers itself, in process and at once, behind a reserved address: Clipboard
/// History and Agent History. Answered like an extension's command, except that it has no process.
@MainActor protocol HostCommand: AnyObject, Sendable {
  var id: String { get }
  nonisolated static var title: String { get }
  /// Its row at the root, matched by name like an app's.
  nonisolated static var row: Result { get }
  func view(for request: ProviderRequest) -> ProviderView
  func view(for request: ProviderRequest, fieldChange: Page.Field.Change) -> ProviderView
  /// Whether it is listed at the root and can be opened now.
  nonisolated static func isAvailable(in configuration: Configuration, extensions: [String]) -> Bool
  /// The conversation a submitted request reopens instead of answering with a view (Agent History's
  /// Reopen); nil for any other request.
  func reopened(_ request: ProviderRequest) -> AgentHistory.Run?
}

extension HostCommand {
  func reopened(_ request: ProviderRequest) -> AgentHistory.Run? { nil }
  func view(for request: ProviderRequest, fieldChange: Page.Field.Change) -> ProviderView {
    view(for: request)
  }
}

/// Where every command address resolves: the root, the agent, the native Settings window, or a command
/// whose behavior answers its screen's requests: an extension's (`ExtensionScreen`) or a host command's
/// (`HostScreen`).
@MainActor struct CommandDirectory {
  enum Destination {
    case root
    /// Fills the input and sends nothing.
    case agent
    case settings
    case command(any CommandScreenBehavior)
  }
  let extensions: ExtensionHost
  /// The host commands this launcher answers; headless has none, but lists their rows all the same.
  let hosts: [any HostCommand]
  /// Whether a command is switched on is the configuration's.
  let store: ConfigurationStore
  /// Every host command there is, in the order their rows are offered.
  nonisolated static let registered: [any HostCommand.Type] = [AgentHistory.self, ClipboardHistory.self]

  /// The Settings row at the root; Settings opens its own window rather than a command.
  nonisolated static let settings = Ranking.host(
    "settings", "Settings", icon: "gearshape", keywords: ["preferences"])

  /// Nil for a target that is no command, such as a removed extension.
  func destination(_ target: String?) -> Destination? {
    switch target {
    case nil: .root
    case "agent": .agent
    case "settings": .settings
    case let id?: behavior(of: id).map { .command($0) }
    }
  }
  /// What answers the requests of the command `id`'s screen. Nil when there is no such command.
  func behavior(of id: String) -> (any CommandScreenBehavior)? {
    if extensions.commands[id] != nil { return ExtensionScreen(id: id, directory: self) }
    return host(id).map { HostScreen(host: $0, directory: self) }
  }
  func host(_ id: String?) -> (any HostCommand)? { hosts.first { $0.id == id } }
  /// Whether requests to `id` have something to answer them: an extension's command or a host command.
  func isCommand(_ id: String) -> Bool { extensions.commands[id] != nil || host(id) != nil }
  /// The command's name.
  func name(of id: String) -> String? {
    extensions.commands[id]?.manifest.name ?? host(id).map { type(of: $0).title }
  }
  /// Whether the command may run: an extension or Clipboard History while switched on.
  func isAvailable(_ id: String, in configuration: Configuration) -> Bool {
    if let host = host(id) {
      return type(of: host).isAvailable(in: configuration, extensions: extensions.ids)
    }
    return extensions.commands[id] != nil && configuration.isEnabled(id, extensions: extensions.ids)
  }
  func availableFields(_ id: String, in configuration: Configuration) -> [ExtensionManifest.Field] {
    guard isAvailable(id, in: configuration) else { return [] }
    return behavior(of: id)?.descriptor?.fields ?? []
  }
  /// Why the command cannot run now, shown instead of its view; nil while it may.
  func unavailability(of id: String) -> String? {
    guard isCommand(id) else { return "This extension was removed. Press Esc to go back." }
    guard !isAvailable(id, in: store.configuration) else { return nil }
    return
      "\(name(of: id) ?? id) is switched off. Switch it on in Settings, Extensions, or press Esc to go back."
  }
  /// What a row's hotkey is bound to: an extension's command row, one of its static items (at the root,
  /// or inside the command when the view lists it with the same primary action) or a host command.
  /// Nil for a row with no address of its own, such as an app, a file or a fallback.
  func hotkeyTarget(of result: Result, atRoot: Bool) -> HotkeyTarget? {
    if Self.isRootRow(result) { return HotkeyTarget(target: result.provider) }
    guard let owner = extensions.commands[result.provider] else { return nil }
    if atRoot, result.rootExtensionRow == .command { return HotkeyTarget(target: owner.id) }
    let row = result.row
    guard !atRoot || result.rootExtensionRow == .item else { return nil }
    let programRow = !atRoot && owner.manifest.command != nil
    var id = row.id
    if !programRow {
      let prefix = ExtensionCommand.itemPrefix(row, atRoot: atRoot)
      guard id.hasPrefix(prefix) else { return nil }
      id.removeFirst(prefix.count)
    }
    // A program's row can name either static item. The manifest item wins if both actions match.
    guard
      let item = owner.items.first(where: { item in
        guard item.id == id else { return false }
        if programRow {
          guard let action = row.actions.first else { return false }
          return action.kind == item.actions.first?.kind
        }
        return item.isUserItem == row.isUserItem
      })
    else { return nil }
    return HotkeyTarget(target: owner.id, item: item.id, isUserItem: item.isUserItem)
  }
  /// The host's rows at the root, before ranking: Settings and the host commands available now.
  func rootRows(_ configuration: Configuration) -> [Result] {
    let available = Self.registered.filter { $0.isAvailable(in: configuration, extensions: extensions.ids) }
    return [Self.settings] + available.map { $0.row }
  }
  /// Whether a root row is the host's own (Settings or a host command's), which a hotkey can open.
  nonisolated static func isRootRow(_ result: Result) -> Bool {
    result.row.id == "open"
      && ([settings] + registered.map { $0.row }).contains { $0.provider == result.provider }
  }
}

/// An extension's command: its static items at once, or its program's view. It reads the extension
/// by its id at each request, so a changed extension answers the next one and a removed one says so.
struct ExtensionScreen: CommandScreenBehavior {
  let id: String
  let directory: CommandDirectory
  private var command: ExtensionCommand? { directory.extensions.commands[id] }
  var descriptor: CommandDescriptor? {
    command.map {
      CommandDescriptor(
        name: $0.manifest.name, fields: $0.manifest.fields, submits: $0.manifest.submit,
        hidden: $0.manifest.hidden, asksAbout: true)
    }
  }
  func work(for request: CommandScreenRequest) -> CommandWork {
    if let problem = directory.unavailability(of: id) { return .unavailable(problem) }
    guard let command else { return .keepView }
    // A submit command runs only when an address is followed, Return included: typing, voice and
    // refreshes leave its view and a running request alone, and nothing stays selected.
    if request.cause == .rerun, command.manifest.submit == true { return .keepView }
    if command.manifest.command == nil {
      return .immediate(.view(ProviderView(items: command.ownItems(request.input))))
    }
    let extensions = directory.extensions
    return .deferred {
      do {
        return .view(try await extensions.view(command, request: request.provider))
      } catch {
        return .problem(command.report(request.provider, error: error), summary: error.localizedDescription)
      }
    }
  }
  func agentContext(from shown: CommandScreen.Shown) -> AgentContext? {
    command.map { AgentContext($0, shown: shown) }
  }
}

/// A host command's screen: its list, answered at once from its store.
struct HostScreen: CommandScreenBehavior {
  let host: any HostCommand
  let directory: CommandDirectory
  var id: String { host.id }
  var descriptor: CommandDescriptor? {
    CommandDescriptor(
      name: type(of: host).title,
      fields: [.init(name: "query", type: .text, description: "Filter history")],
      submits: false, asksAbout: false)
  }
  func work(for request: CommandScreenRequest) -> CommandWork {
    if let problem = directory.unavailability(of: id) { return .unavailable(problem) }
    let provider = request.provider
    if let change = request.fieldChange {
      return .immediate(.view(host.view(for: provider, fieldChange: change)))
    }
    if let run = host.reopened(provider) {
      return .immediate(.restore(run))
    }
    return .immediate(.view(host.view(for: provider)))
  }
  func agentContext(from shown: CommandScreen.Shown) -> AgentContext? { nil }
}
