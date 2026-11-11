/// A window-free keyboard policy. AppKit supplies physical key codes, modifiers and IME state.
enum PaletteKeyAction: Equatable, Sendable {
  enum Edit: Equatable, Sendable { case cut, copy, paste, selectAll, undo, redo }
  case dismiss, run, send
  case permission(Bool)
  case move(Int)
  /// Tab and Shift+Tab between the input and the argument slots.
  case focus(Int)
  case edit(Edit)
  case consume, passThrough

  static func decide(
    keyCode: Int, characters: String?, modifiers: Shortcut.Modifiers, hasMarkedText: Bool,
    permissionPending: Bool = false, isARepeat: Bool = false, hasArguments: Bool = false
  ) -> Self {
    if permissionPending && isARepeat { return .consume }
    guard !hasMarkedText else { return .passThrough }
    if permissionPending {
      if modifiers.isEmpty, keyCode == 53 { return .permission(false) }
      if modifiers == .command, keyCode == 36 || keyCode == 76 { return .permission(true) }
      if keyCode == 36 || keyCode == 76 { return .consume }
    }
    // Tab is AppKit's wherever no slots are shown, such as the confirmation card's buttons.
    if keyCode == 48, hasArguments, !permissionPending, modifiers.isEmpty || modifiers == .shift {
      return .focus(modifiers.isEmpty ? 1 : -1)
    }
    if modifiers.isEmpty {
      switch keyCode {
      case 53: return .dismiss
      case 36, 76: return .run
      case 125: return .move(1)
      case 126: return .move(-1)
      default: break
      }
    }
    if modifiers == .control {
      if characters == "n" { return .move(1) }
      if characters == "p" { return .move(-1) }
    }
    if modifiers == .command, keyCode == 36 || keyCode == 76 { return .send }
    if modifiers == .command {
      switch characters?.lowercased() {
      case "x": return .edit(.cut)
      case "c": return .edit(.copy)
      case "v": return .edit(.paste)
      case "a": return .edit(.selectAll)
      case "z": return .edit(.undo)
      default: return .consume
      }
    }
    if modifiers == [.command, .shift], characters?.lowercased() == "z" { return .edit(.redo) }
    return modifiers.contains(.command) ? .consume : .passThrough
  }
}
