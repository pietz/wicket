/// Registration policy is tested with fake handles; tests never take a system shortcut.
@MainActor
final class PaletteHotKey {
  private let register: (Shortcut) -> AnyObject?
  private var registration: AnyObject?
  private var previous: Shortcut?
  private var paused = false
  var inEffect: Shortcut? { registration == nil ? nil : previous }
  init(register: @escaping (Shortcut) -> AnyObject?) { self.register = register }

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
      return
        "\(shortcut.symbols) is in use. \(inEffect?.symbols ?? "Menu bar → Open Wicket") still opens Wicket."
    }
    registration = replacement
    previous = shortcut
    return nil
  }
}
