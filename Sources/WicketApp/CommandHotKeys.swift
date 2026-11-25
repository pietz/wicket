import Foundation

/// A command address, a manifest item, or a list entry. URL navigation itself only reads the command.
struct HotkeyTarget: Hashable, Sendable, CustomStringConvertible {
  let target: String?
  let input: String?
  let item: String?
  let entryList: String?
  /// Only read from existing config files so migration can replace the binding without losing its keys.
  let legacyItem: Bool

  init(
    target: String?, input: String? = nil, item: String? = nil, entryList: String? = nil,
    legacyItem: Bool = false
  ) {
    self.target = target
    self.input = input
    self.item = item
    self.entryList = entryList
    self.legacyItem = legacyItem
  }
  init?(_ spelling: String, allowLegacy: Bool = false) {
    guard let url = URL(string: spelling), let address = Address(url: url) else { return nil }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let references = query.filter { ["item", "entry", "user-item"].contains($0.name) }
    guard references.count <= 1 else { return nil }
    guard let reference = references.first else {
      self.init(target: address.targetID, input: address.input)
      return
    }
    guard let item = reference.value, !item.isEmpty else { return nil }
    if reference.name == "entry" {
      let parts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
        address.targetID?.hasPrefix("extension:") == true
      else { return nil }
      self.init(
        target: address.targetID, input: address.input, item: String(parts[1]), entryList: String(parts[0]))
    } else {
      let legacy = reference.name == "user-item"
      guard !legacy || allowLegacy else { return nil }
      self.init(target: address.targetID, input: address.input, item: item, legacyItem: legacy)
    }
  }
  var address: Address {
    guard let target else { return Address(extensionName: "", input: input, link: true) }
    return Address(id: target, input: input, link: true)
  }
  var description: String {
    var url = address.linkComponents
    if let item {
      let reference: URLQueryItem =
        if let entryList { URLQueryItem(name: "entry", value: entryList + "/" + item) } else {
          URLQueryItem(name: legacyItem ? "user-item" : "item", value: item)
        }
      url.queryItems = (url.queryItems ?? []) + [reference]
    }
    return url.string ?? "wicket://"
  }
}

struct HotkeyRegistrations: Codable, Equatable, Sendable {
  enum Resolution: String, Codable, Sendable {
    case ok, disabled, duplicate
    case missingExtension = "missing extension"
    case missingCommand = "missing command"
    case missingItem = "missing item"
    case missingPermission = "missing permission"
    case invalidAction = "invalid action"
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

  static func conflicts(_ hotkeys: [Configuration.Hotkey], launcher: Shortcut?)
    -> [HotkeyTarget: Resolution]
  {
    var conflicts: [HotkeyTarget: Resolution] = [:]
    var claimed: Set<Shortcut> = []
    for binding in hotkeys where !binding.target.legacyItem {
      if binding.keys == launcher {
        conflicts[binding.target] = .conflictsWithLauncher
      } else if !claimed.insert(binding.keys).inserted {
        conflicts[binding.target] = .duplicate
      }
    }
    return conflicts
  }

  static func target(_ target: HotkeyTarget) -> String {
    HotkeyTarget(
      target: target.target, item: target.item, entryList: target.entryList, legacyItem: target.legacyItem
    ).description
  }
}

extension ExtensionCommand {
  var commandHotkeyTarget: HotkeyTarget? {
    manifest.hasCommandPage ? HotkeyTarget(target: id) : nil
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
  private(set) var failures: [HotkeyTarget: HotkeyRegistrations.Entry] = [:]

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
    let hotkeys = hotkeys.filter { !$0.target.legacyItem }
    let listed = Set(hotkeys.map(\.target))
    registrations = registrations.filter { listed.contains($0.key) }
    let conflicts = HotkeyRegistrations.conflicts(hotkeys, launcher: launcher)
    let requested = Dictionary(
      uniqueKeysWithValues: hotkeys.filter { conflicts[$0.target] == nil }.map {
        ($0.keys, $0.target)
      })
    var released: [HotkeyTarget: Shortcut] = [:]
    func release(_ target: HotkeyTarget) {
      released[target] = inEffect(target)
      registrations[target] = nil
    }

    var problems: [HotkeyTarget: (HotkeyRegistrations.Resolution, String)] = [:]
    var pending: [Configuration.Hotkey] = []
    for binding in hotkeys {
      let target = binding.target
      let keys = binding.keys
      switch conflicts[target] {
      case .conflictsWithLauncher:
        problems[target] = (.conflictsWithLauncher, launcherConflict(keys, target))
      case .duplicate:
        problems[target] = (.duplicate, "\(keys.symbols) is already assigned to another hotkey.")
      default: pending.append(binding)
      }
      if conflicts[target] != nil, let old = inEffect(target), requested[old] != nil {
        release(target)
      }
    }

    while !pending.isEmpty {
      let waiting = Set(pending.map(\.target))
      let owners = Dictionary(
        uniqueKeysWithValues: registrations.compactMap { target, registration in
          registration.inEffect.map { ($0, target) }
        })
      var ready = pending.filter { binding in
        guard let owner = owners[binding.keys], owner != binding.target else { return true }
        return !waiting.contains(owner)
      }
      if ready.isEmpty {
        // The remaining bindings exchange keys with each other. Release them as a group.
        ready = pending
        for binding in ready { release(binding.target) }
      }
      let targets = Set(ready.map(\.target))
      pending.removeAll { targets.contains($0.target) }
      for binding in ready {
        let (resolution, problem) = register(binding.keys, for: binding.target, launcher: launcher)
        if let problem { problems[binding.target] = (resolution, problem) }
      }
    }
    // If a replacement failed, restore the old keys if no other registration took them.
    for binding in hotkeys where problems[binding.target] != nil {
      if let old = released[binding.target] {
        _ = register(old, for: binding.target, launcher: launcher)
      }
    }

    failures = [:]
    latest = hotkeys.map { binding in
      let shortcut = binding.keys.description
      let target = HotkeyRegistrations.target(binding.target)
      let resolution = problems[binding.target]?.0 ?? .ok
      let summary: String? =
        switch resolution {
        case .conflictsWithLauncher: "\(shortcut) opens Wicket."
        case .duplicate: "\(shortcut) is registered for another binding."
        case .registrationFailed: "\(shortcut) for \(target) could not be registered."
        default: nil
        }
      let entry = HotkeyRegistrations.Entry(
        shortcut: shortcut, target: target, resolution: resolution, problem: summary,
        inEffect: inEffect(binding.target)?.description)
      if summary != nil { failures[binding.target] = entry }
      return entry
    }
    let messages = hotkeys.compactMap { problems[$0.target]?.1 }
    return messages.isEmpty ? nil : messages.joined(separator: "\n")
  }

  private func launcherConflict(_ keys: Shortcut, _ target: HotkeyTarget) -> String {
    "\(keys.symbols) opens Wicket. Choose another for \(target)."
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
      return (.conflictsWithLauncher, launcherConflict(keys, target))
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
