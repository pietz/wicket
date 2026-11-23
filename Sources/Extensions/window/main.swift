// Wicket's window commands: halves, maximize, almost maximize, center, next display and restore, for the
// focused window of the frontmost app. The commands are the items in wicket.json, so typing `left`
// finds Left Half without running anything; choosing one runs this program with its named move action in a submitted
// request, and only that touches a window. Any other request lists the same items.
//
// Moving another app's window takes the Accessibility API, and macOS grants it to the responsible
// process: Wicket, which started this one. The manifest declares `accessibility`, so Wicket runs this
// program only while it holds the grant and shows its own row otherwise.
//
// AppKit is linked for two things nothing lower offers publicly: NSScreen's visible frame (the screen
// without the menu bar and Dock) and NSWorkspace's frontmost app. Linked but unused it costs about 2 ms,
// so the list stays as fast as the calculator; a move connects to the window server, about 60 ms.
// After editing, build it with `swiftc -O *.swift -o main`.
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

/// The commands, by the `move` argument their items set.
enum Move: String, CaseIterable {
  case left, right, top, bottom, maximize
  case almostMaximize = "almost-maximize"
  case center
  case nextDisplay = "next-display"
  case restore
}

/// A display in the Accessibility API's global coordinates: the origin at the top left of the main
/// display, y growing down. `visible` leaves out the menu bar and the Dock.
struct Display: Equatable {
  var frame: CGRect
  var visible: CGRect
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

/// The user's settings (`request.settings`): `gap`, the points between a window and the screen's edges
/// and between halves, and `almostMaximize`, the percent of each side Almost Maximize takes.
struct Layout: Equatable {
  var gap: CGFloat = 0
  var almost: CGFloat = 0.9
  /// Values that are no number, or out of range, keep the default.
  init(gap: String? = nil, almostMaximize: String? = nil) {
    if let value = gap.flatMap(Double.init), (0...200).contains(value) { self.gap = value.rounded() }
    if let value = almostMaximize.flatMap(Double.init), (10...100).contains(value) { almost = value / 100 }
  }
}

/// Where a move puts a window, on whole points of its display's visible frame. Nil for `restore`, which
/// reads where the window was, and for `nextDisplay` with a single display.
func target(_ move: Move, window: CGRect, displays: [Display], layout: Layout = Layout()) -> CGRect? {
  guard !displays.isEmpty else { return nil }
  let index = displayIndex(of: window, in: displays)
  let visible = displays[index].visible
  let gap = min(layout.gap, (min(visible.width, visible.height) / 4).rounded(.down))
  let screen = visible.insetBy(dx: gap, dy: gap)
  /// The screen in two along an axis, the gap between them; the second half takes the odd point.
  func halves(_ edge: CGRectEdge) -> (CGRect, CGRect) {
    let size = edge == .minXEdge ? screen.width : screen.height
    let (first, rest) = screen.divided(atDistance: ((size - gap) / 2).rounded(.down), from: edge)
    return (first, rest.divided(atDistance: gap, from: edge).remainder)
  }
  func centered(_ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(
      x: screen.minX + ((screen.width - width) / 2).rounded(.down),
      y: screen.minY + ((screen.height - height) / 2).rounded(.down), width: width, height: height)
  }
  switch move {
  case .left: return halves(.minXEdge).0
  case .right: return halves(.minXEdge).1
  case .top: return halves(.minYEdge).0
  case .bottom: return halves(.minYEdge).1
  case .maximize: return screen
  case .almostMaximize:
    return centered(
      min((visible.width * layout.almost).rounded(), screen.width),
      min((visible.height * layout.almost).rounded(), screen.height))
  case .center: return centered(min(window.width, screen.width), min(window.height, screen.height))
  case .nextDisplay:
    guard displays.count > 1 else { return nil }
    // Left to right, then top to bottom, wrapping around: the order the displays stand in.
    let order = displays.indices.sorted {
      (displays[$0].frame.minX, displays[$0].frame.minY) < (displays[$1].frame.minX, displays[$1].frame.minY)
    }
    let next = displays[order[(order.firstIndex(of: index)! + 1) % order.count]].visible
    let screen = visible
    // The same place and share of the screen, so a left half stays a left half; never past its edges.
    let scaleX = next.width / screen.width
    let scaleY = next.height / screen.height
    let width = min((window.width * scaleX).rounded(), next.width)
    let height = min((window.height * scaleY).rounded(), next.height)
    let x = (next.minX + (window.minX - screen.minX) * scaleX).rounded()
    let y = (next.minY + (window.minY - screen.minY) * scaleY).rounded()
    return CGRect(
      x: min(max(x, next.minX), next.maxX - width), y: min(max(y, next.minY), next.maxY - height),
      width: width, height: height)
  case .restore: return nil
  }
}

// MARK: - Restore

/// A move Wicket made: the app, the window's frame before and where it ended up (which the app may have
/// adjusted, such as a terminal snapping to its character grid).
struct Record: Equatable {
  var pid: Int32
  var before: CGRect
  var after: CGRect
}

/// The records file: one move per line, the pid and the two frames as x, y, width and height.
func parse(records text: String) -> [Record] {
  text.split(separator: "\n").compactMap { line in
    let fields = line.split(separator: " ")
    guard fields.count == 9, let pid = Int32(fields[0]) else { return nil }
    let numbers = fields.dropFirst().compactMap { Double($0) }
    guard numbers.count == 8 else { return nil }
    return Record(
      pid: pid, before: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
      after: CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7]))
  }
}
func format(_ records: [Record]) -> String {
  records.map { record in
    ([String(record.pid)]
      + [record.before, record.after].flatMap { [$0.minX, $0.minY, $0.width, $0.height] }.map {
        String(Double($0))
      }).joined(separator: " ") + "\n"
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

private struct SystemWindowAccessibility: WindowAccessibility {
  private let app: AXUIElement
  private let enhancedAttribute = "AXEnhancedUserInterface"

  init(pid: pid_t) {
    app = AXUIElementCreateApplication(pid)
    // A hung app would otherwise hold the request for the API's default six seconds.
    AXUIElementSetMessagingTimeout(app, 1)
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
  }

  func focusedWindow() -> (AXError, AXUIElement?) {
    var (error, value) = attribute(app, kAXFocusedWindowAttribute)
    if value == nil, error != .apiDisabled { (error, value) = attribute(app, kAXMainWindowAttribute) }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (error, nil) }
    let window = value as! AXUIElement
    AXUIElementSetMessagingTimeout(window, 1)
    return (error, window)
  }

  func isFullScreen(_ window: AXUIElement) -> (AXError, Bool) {
    let (error, value) = attribute(window, "AXFullScreen")
    return (error, error == .success && (value as? Bool) == true)
  }

  func frame(_ window: AXUIElement) -> (AXError, CGRect?) {
    let (positionError, position) = attribute(window, kAXPositionAttribute)
    let (sizeError, extent) = attribute(window, kAXSizeAttribute)
    if positionError == .apiDisabled || sizeError == .apiDisabled { return (.apiDisabled, nil) }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard positionError == .success, sizeError == .success, let position, let extent,
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
  _ destination: CGRect, to window: AX.Window, using ax: AX
) -> (denied: Bool, actual: CGRect?) {
  let (error, enhanced) = ax.enhancedUserInterface()
  if error == .apiDisabled { return (true, nil) }
  // Chromium and Electron can defer geometry changes while Enhanced User Interface is on.
  defer { if enhanced { _ = ax.setEnhancedUserInterface(true) } }
  if enhanced, ax.setEnhancedUserInterface(false) == .apiDisabled { return (true, nil) }

  // Shrink before moving to a smaller display and size again there, where the first size may not have fit.
  let firstSize = ax.setSize(destination.size, of: window)
  let position = ax.setPosition(destination.origin, of: window)
  let finalSize = ax.setSize(destination.size, of: window)
  let (readback, actual) = ax.frame(window)
  return ([firstSize, position, finalSize, readback].contains(.apiDisabled), actual)
}

// MARK: - Main

/// A row as JSON: why nothing moved.
func row(_ title: String, icon: String, subtitle: String? = nil, actions: String = "[]") -> String {
  #"{"id":"status","title":\#(quoted(title)),"#
    + (subtitle.map { #""subtitle":\#(quoted($0)),"# } ?? "")
    + #""icon":\#(quoted(icon)),"actions":\#(actions)}"#
}
func problem(_ title: String, _ subtitle: String? = nil) -> String {
  row(title, icon: "exclamationmark.triangle", subtitle: subtitle)
}

// Keep the recovery wording and action in step with the host's Accessibility gate.
private func accessibilityProblem(_ commandName: String) -> String {
  row(
    "Allow Accessibility for Wicket", icon: "lock",
    subtitle: "\(commandName) needs it. Already on? Remove Wicket there and add it again",
    actions:
      #"[{"type":"open","title":"Open Privacy & Security","url":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}]"#
  )
}

/// Returns a problem row when the requested frame could not be verified.
func perform<AX: WindowAccessibility>(
  _ move: Move, layout: Layout, pid: Int32, name: String, commandName: String,
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
  guard lock >= 0 else { return problem("Window Manager can't open its move history") }
  defer { close(lock) }
  guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return problem("Another window move is in progress") }

  let (frameError, current) = ax.frame(window)
  if frameError == .apiDisabled { return accessibilityProblem(commandName) }
  guard let current else { return problem("\(name)'s window has no frame to move") }

  var records = contents(recordsFile.path).map { parse(records: String(decoding: $0, as: UTF8.self)) } ?? []
  var restore: Int?
  let destination: CGRect
  if move == .restore {
    guard let index = restoreIndex(records, pid: pid, frame: current) else {
      return problem("Nothing to restore", "Wicket has not moved this window, or it moved since")
    }
    restore = index
    destination = records[index].before
  } else {
    guard let rect = target(move, window: current, displays: displays(), layout: layout) else {
      return problem("Only one display")
    }
    destination = rect
  }

  let (denied, actual) = writeFrame(destination, to: window, using: ax)
  let failed = "\(name)'s window can't be moved"
  guard let actual else { return denied ? accessibilityProblem(commandName) : problem(failed) }
  let applied = framesMatch(actual, destination)
  let changed = actual != current
  if let restore, applied {
    records.remove(at: restore)
  } else if changed {
    if let restore {
      // A partial Restore can be retried from the verified frame it left behind.
      records[restore].after = actual
    } else {
      records.append(Record(pid: pid, before: current, after: actual))
    }
  }
  if changed || (restore != nil && applied) {
    let recordLimit = 50
    try? Data(format(records.suffix(recordLimit)).utf8).write(to: recordsFile, options: .atomic)
  }
  if denied { return accessibilityProblem(commandName) }
  if applied { return nil }
  if changed {
    let next = restore == nil ? "Use Restore to undo the change" : "Try Restore again"
    return problem("\(name)'s window only moved partway", next)
  }
  return problem(failed)
}

@MainActor private func screenDisplays() -> [Display] {
  let screens = NSScreen.screens
  let mainHeight = screens.first?.frame.height ?? 0
  return screens.map {
    Display(
      frame: topDown($0.frame, mainHeight: mainHeight),
      visible: topDown($0.visibleFrame, mainHeight: mainHeight))
  }
}

@MainActor private func perform(_ move: Move, layout: Layout, commandName: String) -> String? {
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

let request = JSON.standardInput()
let manifestBytes = contents("wicket.json") ?? []
var position = 0
let manifest = JSON.read(manifestBytes, &position)
var commands = ""
if case .array(let range)? = manifest?["items"] {
  // The manifest's items without their brackets: the commands, written once.
  commands = String(String(decoding: manifestBytes[range], as: UTF8.self).dropFirst().dropLast())
}
// Only the user's choice moves a window; every other request is the list. A move that worked prints
// nothing, since the window moving is the feedback (the items' runs are hidden); one that did not shows
// why, which filtering the command replaces with the list again.
var failure: String?
if case .bool(true)? = request?["submitted"],
  let move = request?["action"]?.string.flatMap(Move.init(rawValue:))
{
  let settings = request?["settings"]
  let layout = Layout(gap: settings?["gap"]?.string, almostMaximize: settings?["almostMaximize"]?.string)
  failure = perform(move, layout: layout, commandName: manifest?["name"]?.string ?? "Window Manager")
  if failure == nil { exit(0) }
}
print(answer(problem: failure, commands: commands))
