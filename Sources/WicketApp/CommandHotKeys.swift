import Foundation

/// What a global hotkey from `hotkeys` in config.json is bound to: an address spelled as a URL
/// (`wicket://clipboard`, `wicket://weather?input=berlin`), or one of an extension's manifest items, named by
/// `item` (`wicket://window?item=left`). The `item` query is read only here: followed as a link, the
/// address opens the command and ignores it, as it ignores any query item but `input`.
struct HotkeyTarget: Hashable, Sendable, CustomStringConvertible {
  /// `Address.targetID`: a reserved name, an extension ID, or nil for a root query.
  let target: String?
  let input: String?
  let item: String?

  init(target: String?, input: String? = nil, item: String? = nil) {
    self.target = target
    self.input = input
    self.item = item
  }
  init?(_ spelling: String) {
    guard let url = URL(string: spelling), let address = Address(url: url) else { return nil }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    self.init(target: address.targetID, input: address.input, item: query?.first { $0.name == "item" }?.value)
  }
  /// The address that opens it: a link, so its request is never chosen.
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
    let query = [("input", input), ("item", item)].compactMap { name, value in
      value.map { URLQueryItem(name: name, value: $0) }
    }
    url.queryItems = query.isEmpty ? nil : query
    return url.string ?? "wicket://"
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
    let problems = hotkeys.compactMap { set($0.keys, for: $0.target, launcher: launcher) }
    return problems.isEmpty ? nil : problems.joined(separator: "\n")
  }

  /// Registers `keys` for `target` before anything saves it; on a conflict the binding in effect stays.
  /// Nil removes the binding.
  func set(_ keys: Shortcut?, for target: HotkeyTarget, launcher: Shortcut?) -> String? {
    guard let keys else {
      registrations[target] = nil
      return nil
    }
    let registration = registrations[target] ?? makeRegistration(target)
    registrations[target] = registration
    if keys == launcher { return "\(keys.symbols) opens Wicket. Choose another for \(target)." }
    if let other = registrations.first(where: { $0.key != target && $0.value.inEffect == keys }) {
      return "\(keys.symbols) is already the hotkey for \(other.key)."
    }
    return registration.apply(keys)
  }
  private func makeRegistration(_ target: HotkeyTarget) -> HotKeyRegistration {
    let registration = HotKeyRegistration(
      inUse: { "\($0.symbols) for \(target) is in use." + ($1.map { " \($0.symbols) still works." } ?? "") },
      register: { [weak self, register] shortcut in register(shortcut) { self?.onPress(target) } })
    registration.pause(paused)
    return registration
  }
}
