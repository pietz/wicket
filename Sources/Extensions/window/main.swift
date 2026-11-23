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
  records.lastIndex { record in
    record.pid == pid
      && [
        (record.after.minX, frame.minX), (record.after.minY, frame.minY),
        (record.after.width, frame.width), (record.after.height, frame.height),
      ].allSatisfy { abs($0 - $1) <= 1 }
  }
}

/// The last moves, in the user's temporary folder: a window's frames mean nothing after a restart,
/// and a bundled extension's own folder is inside the signed app.
let recordsPath: String = {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
  let folder =
    length > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self) : "/tmp/"
  return folder + "wicket-window-moves.txt"
}()
let recordLimit = 50

func saveRecords(_ records: [Record]) {
  let temporary = recordsPath + ".new"
  guard let file = fopen(temporary, "w") else { return }
  fputs(format(records.suffix(recordLimit)), file)
  fclose(file)
  rename(temporary, recordsPath)
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  return (error, value)
}

func frame(of window: AXUIElement) -> CGRect? {
  var origin = CGPoint.zero
  var size = CGSize.zero
  guard case (.success, let position?) = attribute(window, kAXPositionAttribute),
    case (.success, let extent?) = attribute(window, kAXSizeAttribute),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
    AXValueGetValue(position as! AXValue, .cgPoint, &origin),
    AXValueGetValue(extent as! AXValue, .cgSize, &size)
  else { return nil }
  return CGRect(origin: origin, size: size)
}

/// Sets size, then position, then size again: a window going to a smaller display is shrunk before it
/// moves and sized again once there, where the first size may not have fit.
func setFrame(_ window: AXUIElement, _ rect: CGRect) -> Bool {
  var origin = rect.origin
  var size = rect.size
  guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else {
    return false
  }
  _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
  let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
  let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
  return moved == .success || sized == .success
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

/// Does the move on the frontmost app's focused window: nil when it moved, else a row that says why not.
@MainActor func perform(_ move: Move, layout: Layout) -> String? {
  // The panel does not activate Wicket, so the app the user came from is still frontmost.
  guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getppid() else {
    return problem("No window to move", "Switch to the window, then open Wicket")
  }
  let name = app.localizedName ?? "the app"
  let element = AXUIElementCreateApplication(app.processIdentifier)
  // A hung app would otherwise hold the request for the API's default six seconds (set on each element).
  AXUIElementSetMessagingTimeout(element, 1)
  var (error, value) = attribute(element, kAXFocusedWindowAttribute)
  if value == nil, error != .apiDisabled { (error, value) = attribute(element, kAXMainWindowAttribute) }
  // Wicket checked the grant before starting this; the API can still refuse an app.
  if error == .apiDisabled {
    return problem("\(name) refused Accessibility", "Remove Wicket in Privacy & Security and add it again")
  }
  guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
    return problem("\(name) has no window to move")
  }
  let window = value as! AXUIElement
  AXUIElementSetMessagingTimeout(window, 1)
  if case (.success, let full?) = attribute(window, "AXFullScreen"), (full as? Bool) == true {
    return problem("\(name) is in full screen", "Leave full screen to move its window")
  }
  guard let current = frame(of: window) else { return problem("\(name)'s window has no frame to move") }
  let screens = NSScreen.screens
  let mainHeight = screens.first?.frame.height ?? 0
  let displays = screens.map {
    Display(
      frame: topDown($0.frame, mainHeight: mainHeight),
      visible: topDown($0.visibleFrame, mainHeight: mainHeight))
  }
  var records = contents(recordsPath).map { parse(records: String(decoding: $0, as: UTF8.self)) } ?? []
  let destination: CGRect
  if move == .restore {
    guard let index = restoreIndex(records, pid: app.processIdentifier, frame: current) else {
      return problem("Nothing to restore", "Wicket has not moved this window, or it moved since")
    }
    destination = records.remove(at: index).before
  } else {
    guard let rect = target(move, window: current, displays: displays, layout: layout) else {
      return problem("Only one display")
    }
    destination = rect
  }
  guard setFrame(window, destination) else { return problem("\(name)'s window can't be moved") }
  if move != .restore {
    records.append(
      Record(pid: app.processIdentifier, before: current, after: frame(of: window) ?? destination))
  }
  saveRecords(records)
  return nil
}

/// What the program prints: a problem alone, since the panel orders a command's items by what is typed
/// and a matching command would rank above it, else the commands (a JSON array's contents).
func answer(problem: String?, commands: String) -> String { #"{"items":["# + (problem ?? commands) + "]}" }

let request = JSON.standardInput()
let manifest = contents("wicket.json") ?? []
var position = 0
var commands = ""
if case .array(let range)? = JSON.read(manifest, &position)?["items"] {
  // The manifest's items without their brackets: the commands, written once.
  commands = String(String(decoding: manifest[range], as: UTF8.self).dropFirst().dropLast())
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
  failure = perform(move, layout: layout)
  if failure == nil { exit(0) }
}
print(answer(problem: failure, commands: commands))
