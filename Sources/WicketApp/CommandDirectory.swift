import Foundation

/// A command the host answers itself, in process and at once, behind a reserved address: Clipboard
/// History and Agent History. Answered like an extension's command, except that it has no process.
@MainActor protocol HostCommand: AnyObject, Sendable {
  var id: String { get }
  nonisolated static var title: String { get }
  /// Its row at the root, matched by name like an app's.
  nonisolated static var row: Result { get }
  func view(for request: ProviderRequest) -> ProviderView
  /// Whether it is listed at the root and can be opened now.
  nonisolated static func isAvailable(in configuration: Configuration, extensions: [String]) -> Bool
  /// The conversation a submitted request reopens instead of answering with a view (Agent History's
  /// Reopen); nil for any other request.
  func reopened(_ arguments: [String: String]) -> AgentHistory.Run?
}

extension HostCommand {
  func reopened(_ arguments: [String: String]) -> AgentHistory.Run? { nil }
}

/// Where every command address resolves: the root, the agent, the native Settings window, or a command
/// answered by an extension's program or manifest, or by a host command.
@MainActor struct CommandDirectory {
  enum Destination {
    case root
    /// Fills the input and sends nothing.
    case agent
    case settings
    case command(String)
  }
  let extensions: ExtensionHost
  /// The host commands this launcher answers; headless has none, but lists their rows all the same.
  let hosts: [any HostCommand]
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
    case let id?: isCommand(id) ? .command(id) : nil
    }
  }
  func host(_ id: String?) -> (any HostCommand)? { hosts.first { $0.id == id } }
  /// Whether requests to `id` have something to answer them: an extension's command or a host command.
  func isCommand(_ id: String) -> Bool { extensions.commands[id] != nil || host(id) != nil }
  /// The command's name, for the input placeholder and the footer.
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
  /// What answers the command's requests. Nil when there is no such command.
  func source(_ id: String) -> (@MainActor (ProviderRequest) async throws -> ProviderView)? {
    if let command = extensions.commands[id] {
      let extensions = extensions
      return { try await extensions.view(command, request: $0) }
    }
    guard let host = host(id) else { return nil }
    return { host.view(for: $0) }
  }
  /// What the command answers without waiting for anything: an extension's manifest items, or a host
  /// command. Nil when it runs a process.
  func immediateView(_ id: String, _ request: ProviderRequest) -> ProviderView? {
    if let command = extensions.commands[id] {
      return command.manifest.command == nil ? ProviderView(items: command.ownItems(request.input)) : nil
    }
    return host(id)?.view(for: request)
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
