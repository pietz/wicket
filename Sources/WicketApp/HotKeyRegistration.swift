/// One global shortcut and what to do on a conflict: the launcher's, or one of `hotkeys` (`CommandHotKeys`).
/// Registration policy is tested with fake handles; tests never take a system shortcut.
@MainActor
final class HotKeyRegistration {
  private let register: (Shortcut) -> AnyObject?
  /// What a conflict says: the shortcut that could not be registered, and the one still in effect.
  private let inUse: (Shortcut, Shortcut?) -> String
  private var registration: AnyObject?
  private var previous: Shortcut?
  private var paused = false
  var inEffect: Shortcut? { registration == nil ? nil : previous }
  init(
    inUse: @escaping (Shortcut, Shortcut?) -> String = {
      "\($0.symbols) is in use. \($1?.symbols ?? "Menu bar → Open Wicket") still opens Wicket."
    }, register: @escaping (Shortcut) -> AnyObject?
  ) {
    self.inUse = inUse
    self.register = register
  }

  func snapshot(_ shortcut: Shortcut, problem: String?) -> HotkeyRegistrations.Entry {
    .init(
      shortcut: shortcut.description, resolution: problem == nil ? .ok : .registrationFailed,
      problem: problem, inEffect: inEffect?.description)
  }

  func pause(_ paused: Bool) {
    self.paused = paused
    if paused { registration = nil }
  }

  func apply(_ shortcut: Shortcut) -> String? {
    if shortcut.modifiers.subtracting(.shift) == .command, shortcut.key.count == 1,
      shortcut.key.first?.isLetter == true
    {
      return "\(shortcut.symbols) is an editing or app shortcut. Add Control or Option."
    }
    guard !paused, shortcut != inEffect else { return nil }
    // Keep the old registration until its replacement succeeds.
    guard let replacement = register(shortcut) else {
      if registration == nil, let previous { registration = register(previous) }
      return inUse(shortcut, inEffect)
    }
    registration = replacement
    previous = shortcut
    return nil
  }
}
