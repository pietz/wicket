import Foundation

/// A command the host answers itself, in process and at once, behind a reserved address: Clipboard
/// and Agent History. Answered like an extension's command, except that it has no process.
@MainActor protocol HostCommand: AnyObject, Sendable {
  var id: String { get }
  nonisolated static var title: String { get }
  /// Its row at the root, matched by name like an app's.
  nonisolated static var row: Result { get }
  nonisolated static var descriptor: CommandDescriptor { get }
  func view(for request: ProviderRequest) -> ProviderView
  /// Whether it is listed at the root and can be opened now.
  nonisolated static func isAvailable(in configuration: Configuration, extensions: [String]) -> Bool
  /// The conversation a submitted request reopens instead of answering with a view (Agent History's
  /// Reopen); nil for any other request.
  func reopened(_ request: ProviderRequest) -> AgentHistory.Run?
}

extension HostCommand {
  nonisolated static var descriptor: CommandDescriptor {
    CommandDescriptor(
      name: title, fields: [.init(name: "query", type: .text, description: "Filter history")],
      submits: false, asksAbout: false)
  }
  func reopened(_ request: ProviderRequest) -> AgentHistory.Run? { nil }
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
  private func hostType(_ id: String) -> (any HostCommand.Type)? {
    host(id).map { type(of: $0) } ?? Self.registered.first { $0.row.provider == id }
  }
  /// Whether requests to `id` have something to answer them: an extension's command or a host command.
  func isCommand(_ id: String) -> Bool { extensions.commands[id] != nil || host(id) != nil }
  /// The command's name.
  func name(of id: String) -> String? {
    extensions.commands[id]?.manifest.name ?? hostType(id)?.title
  }
  /// Whether the command may run: an extension or Clipboard while switched on.
  func isAvailable(_ id: String, in configuration: Configuration) -> Bool {
    if let host = hostType(id) {
      return host.isAvailable(in: configuration, extensions: extensions.ids)
    }
    return extensions.commands[id] != nil && configuration.isEnabled(id, extensions: extensions.ids)
  }
  func availableFields(_ id: String, in configuration: Configuration) -> [Field] {
    guard isAvailable(id, in: configuration) else { return [] }
    return extensions.commands[id]?.manifest.fields ?? hostType(id)?.descriptor.fields ?? []
  }
  /// Why the command cannot run now, shown instead of its view; nil while it may.
  func unavailability(of id: String) -> String? {
    guard isCommand(id) else { return "This extension was removed. Press Esc to go back." }
    guard !isAvailable(id, in: store.configuration) else { return nil }
    return
      "\(name(of: id) ?? id) is switched off. Switch it on in Settings, Extensions, or press Esc to go back."
  }
  struct ResolvedHotkey {
    enum Delivery {
      case open(Address)
      case item(Result, RowAction)
      case problem(String)
    }
    var resolution: HotkeyRegistrations.Resolution = .ok
    let delivery: Delivery
  }

  func hotkeyTitle(_ target: HotkeyTarget) -> String? {
    if target.item != nil {
      return target.target.flatMap { extensions.commands[$0]?.item(for: target)?.title }
    }
    switch target.target {
    case nil: return "Open Wicket"
    case "agent": return "Ask agent"
    case "settings": return Self.settings.row.title
    case let id?: return name(of: id)
    }
  }

  /// A hotkey can still show a repair, a switched-off command, or a permission gate when pressed.
  func resolveHotkey(
    _ target: HotkeyTarget, permissionStatus: ((Permission) -> Permission.Status)? = nil
  ) -> ResolvedHotkey {
    let status = permissionStatus ?? extensions.permissions.status
    func commandResolution(_ id: String) -> HotkeyRegistrations.Resolution {
      if id == "agent" || id == "settings" { return .ok }
      let command = extensions.commands[id]
      guard command != nil || hostType(id) != nil else { return .missingExtension }
      guard isAvailable(id, in: store.configuration) else { return .disabled }
      if let command, command.manifest.command != nil, !Permissions.missing(command, status: status).isEmpty {
        return .missingPermission
      }
      return .ok
    }

    let open = ResolvedHotkey.Delivery.open(target.address)
    let id = target.target
    let owner = id.flatMap { extensions.commands[$0] }
    guard let itemID = target.item else {
      let resolution: HotkeyRegistrations.Resolution =
        if let owner, owner.commandHotkeyTarget == nil { .missingCommand } else {
          id.map(commandResolution) ?? .ok
        }
      return .init(resolution: resolution, delivery: open)
    }
    guard let id, let owner, let item = owner.item(for: target), let action = itemAction(item, in: id)
    else {
      let name = owner?.manifest.name ?? target.address.extensionName ?? "this extension"
      return .init(
        resolution: owner == nil && id?.hasPrefix("extension:") == true ? .missingExtension : .missingItem,
        delivery: .problem("Entry “\(itemID)” is no longer available in \(name)."))
    }
    // An item may act independently of the permissions its owner's program needs.
    guard isAvailable(id, in: store.configuration) else {
      return .init(resolution: .disabled, delivery: open)
    }
    let delivery = ResolvedHotkey.Delivery.item(Result(provider: id, row: item), action)
    if let problem = OpenPolicy.refusal(action) {
      return .init(resolution: .invalidAction, delivery: .problem(problem))
    }
    switch action.kind {
    case .run(let address):
      if extensions.unopenableLinkTarget(address, from: id) != nil {
        return .init(resolution: .missingCommand, delivery: delivery)
      }
      let destination = address.extensionName == nil ? id : address.targetID
      return .init(resolution: destination.map(commandResolution) ?? .ok, delivery: delivery)
    case .paste:
      return .init(
        resolution: status(.accessibility) == .granted ? .ok : .missingPermission, delivery: delivery)
    default: return .init(delivery: delivery)
    }
  }

  func hotkeyResolutions(permissionStatus: ((Permission) -> Permission.Status)? = nil)
    -> [HotkeyTarget: HotkeyRegistrations.Resolution]
  {
    let config = store.configuration
    var resolutions = HotkeyRegistrations.conflicts(config.hotkeys, launcher: config.hotkey)
    for binding in config.hotkeys where resolutions[binding.target] == nil {
      resolutions[binding.target] =
        resolveHotkey(binding.target, permissionStatus: permissionStatus).resolution
    }
    return resolutions
  }

  /// An item hotkey must do something distinct from opening its owner's command.
  private func itemAction(_ row: Row, in owner: String) -> RowAction? {
    guard let action = row.actions.first else { return nil }
    switch action.kind {
    case .copy, .paste, .open, .reveal, .save: return action
    case .run(let address):
      let otherTarget = address.extensionName != nil && address.targetID != owner
      if otherTarget || address.action != nil || address.hidden || address.input?.isEmpty == false
        || address.fields?.isEmpty == false
      {
        return action
      }
      return nil
    default: return nil
    }
  }

  func itemHotkeyTarget(_ row: Row, in owner: String) -> HotkeyTarget? {
    guard let action = itemAction(row, in: owner) else { return nil }
    if case .run(let address) = action.kind, extensions.unopenableLinkTarget(address, from: owner) != nil {
      return nil
    }
    return HotkeyTarget(target: owner, item: row.id, entryList: row.entryList)
  }

  /// What a row's hotkey is bound to: an extension's command row, one of its static items (at the root,
  /// or inside the command when the view lists it with the same primary action) or a host command.
  /// Nil for a row with no address of its own, such as an app, a file or a fallback.
  func hotkeyTarget(of result: Result, atRoot: Bool) -> HotkeyTarget? {
    if Self.isRootRow(result) { return HotkeyTarget(target: result.provider) }
    guard let owner = extensions.commands[result.provider] else { return nil }
    if atRoot, result.rootExtensionRow == .command { return owner.commandHotkeyTarget }
    let row = result.row
    if let id = row.indexedItemID {
      let target = HotkeyTarget(target: owner.id, item: id, entryList: row.entryList)
      guard let item = owner.item(for: target) else { return nil }
      return itemHotkeyTarget(item, in: owner.id)
    }
    // A program can render a manifest row with its original ID and primary action.
    guard !atRoot, let action = row.actions.first,
      let item = owner.items.first(where: { item in
        item.entryList == nil && item.id == row.id && item.actions.first?.kind == action.kind
      })
    else { return nil }
    return itemHotkeyTarget(item, in: owner.id)
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
  var iconScope: ExtensionIcons.Scope? { command.map(directory.extensions.iconScope) }
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
    // Typing, voice and refreshes leave submit commands and prompts waiting for Return.
    if request.cause == .rerun, request.prompting || command.manifest.submit { return .keepView }
    if let view = command.staticView(for: request.provider) { return .immediate(.view(view)) }
    let extensions = directory.extensions
    return .deferred {
      do {
        return .view(try await extensions.view(command, request: request.provider, trigger: request.trigger))
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
  var descriptor: CommandDescriptor? { type(of: host).descriptor }
  func work(for request: CommandScreenRequest) -> CommandWork {
    if let problem = directory.unavailability(of: id) { return .unavailable(problem) }
    let provider = request.provider
    if let run = host.reopened(provider) {
      return .immediate(.restore(run))
    }
    return .immediate(.view(host.view(for: provider)))
  }
  func agentContext(from shown: CommandScreen.Shown) -> AgentContext? { nil }
}
