// Stock moves live in wicket.json, so typing at the root starts no process. Only a submitted action
// reads or writes windows. Wicket holds the Accessibility grant as the responsible process and gates
// this program through the manifest's accessibility permission.
import AppKit

/// A whole file's bytes, or nil.
func contents(_ path: String) -> [UInt8]? {
  guard let file = fopen(path, "r") else { return nil }
  defer { fclose(file) }
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 1 << 16)
  while case let count = fread(&buffer, 1, buffer.count, file), count > 0 { bytes += buffer[0..<count] }
  return bytes
}

// MARK: - Moves

/// The stock commands, keyed by their manifest item IDs.
enum Move: String, CaseIterable {
  case left, right, maximize, center
  case nextDisplay = "next-display"
  case restore

  var cyclesWidth: Bool { self == .left || self == .right }
}

/// A display in the Accessibility API's global coordinates: the origin at the top left of the main
/// display, y growing down. `visible` leaves out the menu bar and the Dock.
struct Display: Equatable {
  var frame: CGRect
  var visible: CGRect
  var uuid: UUID? = nil
}

/// An AppKit screen rectangle (origin at the bottom left of the main display, y growing up) in the
/// Accessibility API's coordinates, given the main display's height.
func topDown(_ rect: CGRect, mainHeight: CGFloat) -> CGRect {
  CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// The display a window is on: the one holding its center, else the one it overlaps most, else the first.
func displayIndex(of window: CGRect, in displays: [Display]) -> Int {
  let center = CGPoint(x: window.midX, y: window.midY)
  if let index = displays.firstIndex(where: { $0.frame.contains(center) }) { return index }
  let overlaps = displays.map {
    let overlap = $0.frame.intersection(window)
    return overlap.isNull ? 0 : overlap.width * overlap.height
  }
  return overlaps.indices.max { overlaps[$0] < overlaps[$1] } ?? 0
}

struct Layout: Equatable {
  var gap: CGFloat = 0

  init(gap: String? = nil) {
    if let value = gap.flatMap(Double.init), (0...200).contains(value) { self.gap = value.rounded() }
  }

  func gap(in visible: CGRect) -> CGFloat {
    min(gap, (min(visible.width, visible.height) / 4).rounded(.down))
  }
}

/// Where a stock move puts a window. Restore instead reads where the window was.
func target(_ move: Move, window: CGRect, displays: [Display], layout: Layout = Layout()) -> WindowTarget? {
  guard !displays.isEmpty else { return nil }
  let index = displayIndex(of: window, in: displays)
  let visible = displays[index].visible
  let gap = layout.gap(in: visible)
  switch move {
  case .left, .right:
    let anchor: WindowAnchor = move == .left ? .left : .right
    guard let frame = sideTarget(anchor, window: window, visible: visible, gap: gap) else { return nil }
    return WindowTarget(frame: frame, visible: visible, alignment: anchor.position)
  case .maximize:
    guard let frame = Placement(anchor: .center, width: 100, height: 100).frame(in: visible, gap: gap)
    else { return nil }
    return WindowTarget(frame: frame, visible: visible, alignment: WindowAnchor.center.position)
  case .center:
    let screen = visible.insetBy(dx: gap, dy: gap)
    let width = min(window.width, screen.width)
    let height = min(window.height, screen.height)
    let frame = CGRect(
      x: screen.minX + ((screen.width - width) / 2).rounded(.down),
      y: screen.minY + ((screen.height - height) / 2).rounded(.down), width: width, height: height)
    return WindowTarget(frame: frame, visible: visible, alignment: WindowAnchor.center.position)
  case .nextDisplay:
    guard displays.count > 1 else { return nil }
    let next = displays[nextDisplay(after: index, in: displays)].visible
    let screen = visible
    // The same place and share of the screen, so a left half stays a left half; never past its edges.
    let scaleX = next.width / screen.width
    let scaleY = next.height / screen.height
    let width = min((window.width * scaleX).rounded(), next.width)
    let height = min((window.height * scaleY).rounded(), next.height)
    let x = (next.minX + (window.minX - screen.minX) * scaleX).rounded()
    let y = (next.minY + (window.minY - screen.minY) * scaleY).rounded()
    let frame = CGRect(
      x: min(max(x, next.minX), next.maxX - width), y: min(max(y, next.minY), next.maxY - height),
      width: width, height: height)
    let alignment = (
      x: width < next.width ? (frame.minX - next.minX) / (next.width - width) : 0.5,
      y: height < next.height ? (frame.minY - next.minY) / (next.height - height) : 0.5
    )
    return WindowTarget(frame: frame, visible: next, alignment: alignment)
  case .restore: return nil
  }
}

/// Left to right, then top to bottom, wrapping around.
func nextDisplay(after index: Int, in displays: [Display]) -> Int {
  let order = displays.indices.sorted {
    (displays[$0].frame.minX, displays[$0].frame.minY) < (displays[$1].frame.minX, displays[$1].frame.minY)
  }
  return order[(order.firstIndex(of: index)! + 1) % order.count]
}

enum WindowMove {
  case stock(Move)
  case custom(Placement)
}

// MARK: - Restore

/// A move Wicket made: the app, the window's frame before and where it ended up (which the app may have
/// adjusted, such as a terminal snapping to its character grid).
struct Record: Equatable {
  var pid: Int32
  var before: CGRect
  var after: CGRect
  var cycle: Move? = nil
}

/// One move per line: the pid, both frames as x, y, width and height, and an optional side preset.
func parse(records text: String) -> [Record] {
  text.split(separator: "\n").compactMap { line in
    let fields = line.split(separator: " ")
    guard fields.count == 9 || fields.count == 10, let pid = Int32(fields[0]) else { return nil }
    let numbers = fields.dropFirst().prefix(8).compactMap { Double($0) }
    guard numbers.count == 8 else { return nil }
    let cycle = fields.count == 10 ? Move(rawValue: String(fields[9])) : nil
    return Record(
      pid: pid, before: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
      after: CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7]),
      cycle: cycle?.cyclesWidth == true ? cycle : nil)
  }
}
func format(_ records: [Record]) -> String {
  records.map { record in
    let numbers = [record.before, record.after].flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
    let line = ([String(record.pid)] + numbers.map { String(Double($0)) }).joined(separator: " ")
    return line + (record.cycle.map { " " + $0.rawValue } ?? "") + "\n"
  }.joined()
}

/// The latest move of this window: one of its app's that left a window where this one still is (within
/// a point). Restoring it takes it off, so restoring again goes back one more move.
func restoreIndex(_ records: [Record], pid: Int32, frame: CGRect) -> Int? {
  records.lastIndex { $0.pid == pid && framesMatch($0.after, frame) }
}

private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
  abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
    && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
}

let recordsFile: URL = {
  if let directory = getenv("WICKET_DATA_DIR"), directory.pointee != 0 {
    return URL(filePath: String(cString: directory), directoryHint: .isDirectory).appending(path: "moves.txt")
  }
  return URL.temporaryDirectory.appending(path: "wicket-window-manual-moves.txt")
}()

// MARK: - Accessibility

protocol WindowAccessibility {
  associatedtype Window
  func focusedWindow() -> (AXError, Window?)
  func isFullScreen(_ window: Window) -> (AXError, Bool)
  func frame(_ window: Window) -> (AXError, CGRect?)
  func enhancedUserInterface() -> (AXError, Bool)
  func setEnhancedUserInterface(_ enabled: Bool) -> AXError
  func setPosition(_ position: CGPoint, of window: Window) -> AXError
  func setSize(_ size: CGSize, of window: Window) -> AXError
}

struct SystemWindowAccessibility: WindowCaptureAccessibility {
  private let app: AXUIElement
  private let timeout: Float
  private let enhancedAttribute = "AXEnhancedUserInterface"

  init(pid: pid_t, timeout: Float = 1) {
    app = AXUIElementCreateApplication(pid)
    self.timeout = timeout
    // A hung app would otherwise hold the request for the API's default six seconds.
    AXUIElementSetMessagingTimeout(app, timeout)
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
  }

  func focusedWindow() -> (AXError, AXUIElement?) {
    for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      let (error, value) = attribute(app, key)
      if error == .apiDisabled { return (error, nil) }
      guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
      let window = value as! AXUIElement
      let (standardError, standard) = isStandard(window)
      if standardError == .apiDisabled { return (standardError, nil) }
      guard standard else { continue }
      let (minimizedError, minimized) = isMinimized(window)
      if minimizedError == .apiDisabled { return (minimizedError, nil) }
      if minimizedError == .success, !minimized { return (.success, window) }
    }
    return (.noValue, nil)
  }

  func windows(markFocused: Bool) -> (AXError, [(window: AXUIElement, focused: Bool)]) {
    let (error, value) = attribute(app, kAXWindowsAttribute)
    guard let windows = value as? [AXUIElement] else { return (error, []) }
    let (focusError, focused) = markFocused ? attribute(app, kAXFocusedWindowAttribute) : (.success, nil)
    if focusError == .apiDisabled { return (focusError, []) }
    return (error, windows.map { window in (window, focused.map { CFEqual(window, $0) } ?? false) })
  }

  func isStandard(_ window: AXUIElement) -> (AXError, Bool) {
    // AX timeouts are per element. The window does not inherit the app element's timeout.
    AXUIElementSetMessagingTimeout(window, timeout)
    let (error, value) = attribute(window, kAXSubroleAttribute)
    return (error, (value as? String) == kAXStandardWindowSubrole)
  }

  private func windowFlag(_ window: AXUIElement, _ key: String) -> (AXError, Bool) {
    let (error, value) = attribute(window, key)
    if error == .attributeUnsupported || error == .noValue { return (.success, false) }
    return (error, (value as? Bool) == true)
  }

  func isMinimized(_ window: AXUIElement) -> (AXError, Bool) {
    windowFlag(window, kAXMinimizedAttribute)
  }

  func isFullScreen(_ window: AXUIElement) -> (AXError, Bool) {
    windowFlag(window, "AXFullScreen")
  }

  func frame(_ window: AXUIElement) -> (AXError, CGRect?) {
    let (positionError, position) = attribute(window, kAXPositionAttribute)
    guard positionError == .success else { return (positionError, nil) }
    let (sizeError, extent) = attribute(window, kAXSizeAttribute)
    guard sizeError == .success else { return (sizeError, nil) }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let position, let extent,
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
      AXValueGetValue(position as! AXValue, .cgPoint, &origin),
      AXValueGetValue(extent as! AXValue, .cgSize, &size)
    else { return (.failure, nil) }
    return (.success, CGRect(origin: origin, size: size))
  }

  func enhancedUserInterface() -> (AXError, Bool) {
    let (error, value) = attribute(app, enhancedAttribute)
    return (error, error == .success && (value as? Bool) == true)
  }

  func setEnhancedUserInterface(_ enabled: Bool) -> AXError {
    AXUIElementSetAttributeValue(
      app, enhancedAttribute as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
  }

  func setPosition(_ position: CGPoint, of window: AXUIElement) -> AXError {
    var position = position
    guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
    return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
  }

  func setSize(_ size: CGSize, of window: AXUIElement) -> AXError {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
    return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
  }
}

private func writeFrame<AX: WindowAccessibility>(
  _ destination: WindowTarget, to window: AX.Window, using ax: AX
) -> (denied: Bool, actual: CGRect?, cleanupError: AXError) {
  let (error, enhanced) = ax.enhancedUserInterface()
  if error == .apiDisabled { return (true, nil, .success) }
  // Chromium and Electron can defer geometry changes while Enhanced User Interface is on.
  if enhanced, ax.setEnhancedUserInterface(false) == .apiDisabled { return (true, nil, .success) }

  func readFrame() -> (AXError, CGRect?) {
    let result = ax.frame(window)
    return result.0 == .success || result.0 == .apiDisabled ? result : ax.frame(window)
  }

  // Size before crossing displays, then size again on the destination where the request may fit.
  let requested = destination.frame.size
  let firstSize = ax.setSize(requested, of: window)
  let (sizing, sized) = ax.frame(window)
  // Leave space to grow at the new origin if the old origin constrained the first resize.
  let room = CGSize(
    width: max(requested.width, sized?.width ?? 0), height: max(requested.height, sized?.height ?? 0))
  let origin = destination.position(for: room)
  let position = ax.setPosition(origin, of: window)
  let finalSize = ax.setSize(requested, of: window)
  var (readback, actual) = readFrame()
  var correction = AXError.success
  if position == .success, readback == .success, let frame = actual {
    let adjusted = destination.position(for: frame.size)
    if adjusted != origin, adjusted != frame.origin {
      correction = ax.setPosition(adjusted, of: window)
      (readback, actual) = readFrame()
    }
  }

  var cleanupError = AXError.success
  if enhanced {
    cleanupError = ax.setEnhancedUserInterface(true)
    if cleanupError == .cannotComplete { cleanupError = ax.setEnhancedUserInterface(true) }
  }
  let denied = [firstSize, sizing, position, finalSize, readback, correction].contains(.apiDisabled)
  return (denied, actual, cleanupError)
}

// MARK: - Main

/// A status row as JSON.
func row(_ title: String, icon: String, subtitle: String? = nil, actions: String = "[]") -> String {
  #"{"id":"status","title":\#(quoted(title)),"#
    + (subtitle.map { #""subtitle":\#(quoted($0)),"# } ?? "")
    + #""icon":\#(quoted(icon)),"actions":\#(actions)}"#
}
func problem(_ title: String, _ subtitle: String? = nil) -> String {
  row(title, icon: "exclamationmark.triangle", subtitle: subtitle)
}

// Keep the recovery wording and action in step with the host's Accessibility gate.
func accessibilityProblem(
  _ commandName: String, title: String = "Allow Accessibility for Wicket"
) -> String {
  row(
    title, icon: "lock",
    subtitle: "\(commandName) needs it. If on, remove (–) and re-add Wicket.",
    actions:
      #"[{"type":"open","title":"Open Privacy & Security","url":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}]"#
  )
}

/// Returns a problem row if placement or Accessibility cleanup needs attention.
func perform<AX: WindowAccessibility>(
  _ move: WindowMove, layout: Layout, pid: Int32, name: String, commandName: String,
  displays: @autoclosure () -> [Display], recordsFile: URL, ax: AX
) -> String? {
  let (windowError, window) = ax.focusedWindow()
  if windowError == .apiDisabled { return accessibilityProblem(commandName) }
  guard let window else {
    return problem("\(name) has no window to move")
  }
  let (fullScreenError, fullScreen) = ax.isFullScreen(window)
  if fullScreenError == .apiDisabled { return accessibilityProblem(commandName) }
  if fullScreen {
    return problem("\(name) is in full screen", "Leave full screen to move its window")
  }

  // Overlapping hotkeys could re-enable Enhanced User Interface during another frame write.
  let lock = open(
    recordsFile.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
  guard lock >= 0 else { return problem("\(commandName) can't open its move history") }
  defer { close(lock) }
  guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return problem("Another window move is in progress") }
  // A fork can briefly inherit the descriptor even with O_CLOEXEC.
  defer { flock(lock, LOCK_UN) }

  let (frameError, current) = ax.frame(window)
  if frameError == .apiDisabled { return accessibilityProblem(commandName) }
  guard let current else { return problem("\(name)'s window has no frame to move") }

  var records = contents(recordsFile.path).map { parse(records: String(decoding: $0, as: UTF8.self)) } ?? []
  let historyIndex = restoreIndex(records, pid: pid, frame: current)
  var restore: Int?
  var cycle: Move?
  let destination: WindowTarget
  switch move {
  case .stock(.restore):
    guard let index = historyIndex else {
      return problem("Nothing to restore", "Wicket has not moved this window, or it moved since")
    }
    restore = index
    destination = WindowTarget(frame: records[index].before)
  case .stock(let stock):
    let screens = displays()
    guard !screens.isEmpty else { return problem("No display available") }
    guard let target = target(stock, window: current, displays: screens, layout: layout) else {
      if stock == .nextDisplay { return problem("Only one display") }
      return problem("Can't apply window move", "Use a larger move or reduce the gap in Windows Settings")
    }
    if stock.cyclesWidth { cycle = stock }
    destination = target
  case .custom(let placement):
    let screens = displays()
    guard !screens.isEmpty else { return problem("No display available") }
    let visible = screens[displayIndex(of: current, in: screens)].visible
    guard let rect = placement.frame(in: visible, gap: layout.gap(in: visible)) else {
      return problem("Can't apply window move", "Use a larger move or reduce the gap in Windows Settings")
    }
    destination = WindowTarget(frame: rect, visible: visible, alignment: placement.anchor.position)
  }

  let (denied, actual, cleanupError) = writeFrame(destination, to: window, using: ax)
  var cleanupWarning: String?
  if cleanupError != .success {
    let warning = "Couldn't re-enable Enhanced User Interface for \(name)"
    cleanupWarning =
      cleanupError == .apiDisabled || denied
      ? accessibilityProblem(commandName, title: warning) : problem(warning)
  }
  guard let actual else {
    return cleanupWarning
      ?? (denied
        ? accessibilityProblem(commandName) : problem("Couldn't verify \(name)'s final window position"))
  }
  let applied =
    restore != nil ? framesMatch(actual, destination.frame) : placementMatches(actual, destination.frame)
  let changed = actual != current
  if let restore, applied {
    records.remove(at: restore)
  } else if changed {
    if let restore {
      // A partial Restore can be retried from the verified frame it left behind.
      records[restore].after = actual
    } else if let cycle, let historyIndex, records[historyIndex].cycle == cycle {
      var record = records.remove(at: historyIndex)
      record.after = actual
      records.append(record)
    } else {
      records.append(Record(pid: pid, before: current, after: actual, cycle: cycle))
    }
  }
  if changed || (restore != nil && applied) {
    let recordLimit = 50
    try? Data(format(records.suffix(recordLimit)).utf8).write(to: recordsFile, options: .atomic)
  }
  if let cleanupWarning { return cleanupWarning }
  if denied { return accessibilityProblem(commandName) }
  if applied { return nil }
  if changed {
    let next = restore == nil ? "Use Restore to undo the change" : "Try Restore again"
    return problem("\(name)'s window only moved partway", next)
  }
  return problem("\(name)'s window can't be moved")
}

@MainActor func screenDisplays() -> [Display] {
  let screens = NSScreen.screens
  let mainHeight = screens.first?.frame.height ?? 0
  let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
  return screens.map { screen in
    let uuid = (screen.deviceDescription[screenNumber] as? NSNumber).flatMap {
      CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue()
    }.flatMap { UUID(uuidString: CFUUIDCreateString(nil, $0) as String) }
    return Display(
      frame: topDown(screen.frame, mainHeight: mainHeight),
      visible: topDown(screen.visibleFrame, mainHeight: mainHeight), uuid: uuid)
  }
}

@MainActor func perform(_ move: WindowMove, layout: Layout, commandName: String) -> String? {
  // The panel does not activate Wicket, so the app the user came from is still frontmost.
  guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getppid() else {
    return problem("No window to move", "Switch to the window, then open Wicket")
  }
  let pid = app.processIdentifier
  return perform(
    move, layout: layout, pid: pid, name: app.localizedName ?? "the app", commandName: commandName,
    displays: screenDisplays(), recordsFile: recordsFile, ax: SystemWindowAccessibility(pid: pid))
}

/// What the program prints: a problem alone, since the panel orders a command's items by what is typed
/// and a matching command would rank above it, else the commands (a JSON array's contents).
func answer(problem: String?, commands: String) -> String { #"{"items":["# + (problem ?? commands) + "]}" }

/// Nil is a successful hidden move. Non-submitted requests only browse the stock commands.
@MainActor func windowAnswer(
  _ request: JSON?, manifestBytes: [UInt8],
  move: @MainActor (WindowMove, Layout, String) -> String?,
  capture: @MainActor (String, Bool, Layout) -> String
) -> String? {
  var position = 0
  let manifest = JSON.read(manifestBytes, &position)
  if case .bool(true)? = request?["submitted"], let action = request?["action"]?.string {
    let commandName = manifest?["name"]?.string ?? "Windows"
    let settings = request?["settings"]
    let layout = Layout(gap: settings?["gap"]?.string)
    if action == "capture" || action == "save-current" {
      return capture(commandName, action == "save-current", layout)
    }
    if action == "apply-placement" {
      guard let placement = Placement(fields: request?["fields"]) else {
        return answer(
          problem: problem(
            "Invalid window move", "Choose an anchor and enter width and height from 10 to 100%"),
          commands: "")
      }
      return move(.custom(placement), layout, commandName).map { answer(problem: $0, commands: "") }
    }
    if let stock = Move(rawValue: action) {
      return move(.stock(stock), layout, commandName).map { answer(problem: $0, commands: "") }
    }
    return answer(
      problem: problem("Window move is unavailable", "Choose a move in Windows or add one in Settings"),
      commands: "")
  }
  let commands: String
  if case .array(let range)? = manifest?["items"] {
    // The manifest's items without their brackets: the commands, written once.
    commands = String(String(decoding: manifestBytes[range], as: UTF8.self).dropFirst().dropLast())
  } else {
    commands = ""
  }
  return answer(problem: nil, commands: commands)
}
