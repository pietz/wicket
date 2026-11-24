import Foundation

/// What a global hotkey from `hotkeys` in config.json is bound to: an address spelled as a URL
/// (`wicket://clipboard`, `wicket://weather?input=berlin`), or one of an extension's static items, named by
/// `item` for a manifest item (`wicket://window?item=left`) or `user-item` for a user item. These query
/// keys are read only here. Keeping the item's ID lets its current action stay in the extension.
struct HotkeyTarget: Hashable, Sendable, CustomStringConvertible {
  /// `Address.targetID`: a reserved name, an extension ID, or nil for a root query.
  let target: String?
  let input: String?
  let item: String?
  let isUserItem: Bool

  init(target: String?, input: String? = nil, item: String? = nil, isUserItem: Bool = false) {
    self.target = target
    self.input = input
    self.item = item
    self.isUserItem = item != nil && isUserItem
  }
  init?(_ spelling: String) {
    guard let url = URL(string: spelling), let address = Address(url: url) else { return nil }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    let item = query?.first { $0.name == "item" }
    let userItem = query?.first { $0.name == "user-item" }
    guard item == nil || userItem == nil else { return nil }
    if let userItem, userItem.value?.isEmpty != false { return nil }
    self.init(
      target: address.targetID, input: address.input, item: userItem?.value ?? item?.value,
      isUserItem: userItem != nil)
  }
  /// The address that opens it: a link, so its request is never submitted.
  var address: Address {
    guard let target else { return Address(extensionName: "", input: input, link: true) }
    return Address(id: target, input: input, link: true)
  }
  /// `wicket://window?item=left`, the folder percent-encoded, as config.json keeps it.
  var description: String {
    var url = URLComponents()
    url.scheme = Address.schemes[0]
    url.encodedHost = (address.extensionName ?? "").addingPercentEncoding(
      withAllowedCharacters: .urlHostAllowed)
    let query = [("input", input), (isUserItem ? "user-item" : "item", item)].compactMap { name, value in
      value.map { URLQueryItem(name: name, value: $0) }
    }
    url.queryItems = query.isEmpty ? nil : query
    return url.string ?? "wicket://"
  }
}

struct HotkeyRegistrations: Codable, Equatable, Sendable {
  enum Resolution: String, Codable, Sendable {
    case ok, disabled, duplicate
    case missingExtension = "missing extension"
    case missingItem = "missing item"
    case missingPermission = "missing permission"
    case conflictsWithLauncher = "conflicts with launcher"
    case registrationFailed = "registration failed"
  }

  struct Entry: Codable, Equatable, Sendable {
    let shortcut: String
    var target: String? = nil
    var resolution: Resolution = .ok
    var problem: String? = nil
    var inEffect: String? = nil
  }

  let launcher: Entry
  let bindings: [Entry]
  var bindingProblem: String? {
    let messages = bindings.compactMap(\.problem)
    return messages.isEmpty ? nil : messages.joined(separator: "\n")
  }

  static func target(_ target: HotkeyTarget) -> String {
    HotkeyTarget(target: target.target, item: target.item, isUserItem: target.isUserItem).description
  }
}

/// The `hotkeys` of config.json, each its own registration, so a conflict costs only that one and keeps the
/// working registration it would have replaced, as the launcher's shortcut does. Nothing here knows what a
/// press does (`LauncherModel.press`).
@MainActor
final class CommandHotKeys {
  typealias Register = (Shortcut, @escaping @MainActor () -> Void) -> AnyObject?
  private let register: Register
  var onPress: (HotkeyTarget) -> Void = { _ in }
  private var registrations: [HotkeyTarget: HotKeyRegistration] = [:]
  private var paused = false
  private(set) var latest: [HotkeyRegistrations.Entry] = []

  init(register: @escaping Register) { self.register = register }

  /// The shortcut registered for `target` now, if any.
  func inEffect(_ target: HotkeyTarget) -> Shortcut? { registrations[target]?.inEffect }

  /// While Wicket records a shortcut, none fires, so the recorder hears the keys.
  func pause(_ paused: Bool) {
    self.paused = paused
    for registration in registrations.values { registration.pause(paused) }
  }

  /// Registers every binding, keeping those already in effect, and drops those no longer listed.
  /// `launcher` is the launcher's shortcut, which no binding takes. One line per problem, or nil.
  func apply(_ hotkeys: [Configuration.Hotkey], launcher: Shortcut?) -> String? {
    let listed = Set(hotkeys.map(\.target))
    registrations = registrations.filter { listed.contains($0.key) }
    var entries: [HotkeyRegistrations.Entry] = []
    var problems: [String] = []
    for binding in hotkeys {
      let (resolution, problem) = register(binding.keys, for: binding.target, launcher: launcher)
      let shortcut = binding.keys.description
      let target = HotkeyRegistrations.target(binding.target)
      let summary: String? =
        switch resolution {
        case .conflictsWithLauncher: "\(shortcut) opens Wicket."
        case .duplicate: "\(shortcut) is registered for another binding."
        case .registrationFailed: "\(shortcut) for \(target) could not be registered."
        default: nil
        }
      entries.append(
        .init(
          shortcut: shortcut, target: target, resolution: resolution, problem: summary,
          inEffect: inEffect(binding.target)?.description))
      if let problem { problems.append(problem) }
    }
    latest = entries
    return problems.isEmpty ? nil : problems.joined(separator: "\n")
  }

  /// Registers `keys` for `target` before anything saves it; on a conflict the binding in effect stays.
  /// Nil removes the binding.
  func set(_ keys: Shortcut?, for target: HotkeyTarget, launcher: Shortcut?) -> String? {
    guard let keys else {
      registrations[target] = nil
      return nil
    }
    return register(keys, for: target, launcher: launcher).1
  }

  private func register(_ keys: Shortcut, for target: HotkeyTarget, launcher: Shortcut?)
    -> (HotkeyRegistrations.Resolution, String?)
  {
    let registration = registrations[target] ?? makeRegistration(target)
    registrations[target] = registration
    if keys == launcher {
      return (.conflictsWithLauncher, "\(keys.symbols) opens Wicket. Choose another for \(target).")
    }
    if let other = registrations.first(where: { $0.key != target && $0.value.inEffect == keys }) {
      return (.duplicate, "\(keys.symbols) is already the hotkey for \(other.key).")
    }
    let problem = registration.apply(keys)
    return (problem == nil ? .ok : .registrationFailed, problem)
  }
  private func makeRegistration(_ target: HotkeyTarget) -> HotKeyRegistration {
    let registration = HotKeyRegistration(
      inUse: { "\($0.symbols) for \(target) is in use." + ($1.map { " \($0.symbols) still works." } ?? "") },
      register: { [weak self, register] shortcut in register(shortcut) { self?.onPress(target) } })
    registration.pause(paused)
    return registration
  }
}
