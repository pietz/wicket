import AppKit

protocol WindowCaptureAccessibility: WindowAccessibility {
  func windows(markFocused: Bool) -> (AXError, [(window: Window, focused: Bool)])
  func isStandard(_ window: Window) -> (AXError, Bool)
  func isMinimized(_ window: Window) -> (AXError, Bool)
}

struct CaptureApp<AX: WindowCaptureAccessibility> {
  let bundleID: String
  let hidden: Bool
  let frontmost: Bool
  let ax: AX
}

private struct CapturedWindow: Encodable {
  let bundleID: String
  let display: UUID
  let rect: [CGFloat]
  let focused: Bool

  init?(bundleID: String, frame: CGRect, displays: [Display], focused: Bool) {
    guard frame.size.width > 0, frame.size.height > 0,
      let screen = displays.first(where: { $0.visible.contains(frame) }), let uuid = screen.uuid
    else { return nil }
    let visible = screen.visible
    self.bundleID = bundleID
    display = uuid
    rect = [
      (frame.minX - visible.minX) / visible.width, (frame.minY - visible.minY) / visible.height,
      frame.width / visible.width, frame.height / visible.height,
    ]
    self.focused = focused
  }
}

func captureWindows<AX: WindowCaptureAccessibility>(
  _ apps: [CaptureApp<AX>], displays: [Display], commandName: String
) -> String {
  let deadline = ContinuousClock.now + .seconds(7)
  func denied() -> String { answer(problem: accessibilityProblem(commandName), commands: "") }
  func timedOut() -> String {
    answer(
      problem: problem("Window capture timed out", "Close any unresponsive apps and try again"), commands: "")
  }
  var captured: [CapturedWindow] = []
  for app in apps where !app.hidden {
    guard ContinuousClock.now < deadline else { return timedOut() }
    let ax = app.ax
    let (error, windows) = ax.windows(markFocused: app.frontmost)
    if error == .apiDisabled { return denied() }
    for (window, focused) in windows {
      guard ContinuousClock.now < deadline else { return timedOut() }
      let (standardError, standard) = ax.isStandard(window)
      if standardError == .apiDisabled { return denied() }
      guard standardError == .success, standard else { continue }
      let (minimizedError, minimized) = ax.isMinimized(window)
      if minimizedError == .apiDisabled { return denied() }
      guard minimizedError == .success, !minimized else { continue }
      let (fullScreenError, fullScreen) = ax.isFullScreen(window)
      if fullScreenError == .apiDisabled { return denied() }
      guard fullScreenError == .success, !fullScreen else { continue }
      let (frameError, frame) = ax.frame(window)
      if frameError == .apiDisabled { return denied() }
      if let frame, frameError == .success,
        let entry = CapturedWindow(bundleID: app.bundleID, frame: frame, displays: displays, focused: focused)
      {
        captured.append(entry)
      }
    }
  }
  guard let data = try? JSONEncoder().encode(captured) else {
    return answer(problem: problem("Couldn't encode captured windows"), commands: "")
  }
  return #"{"body":\#(quoted(String(decoding: data, as: UTF8.self)))}"#
}

func saveCurrentWindow<AX: WindowAccessibility>(
  _ ax: AX, displays: [Display], commandName: String, layout: Layout
) -> String {
  func denied() -> String { answer(problem: accessibilityProblem(commandName), commands: "") }
  func unavailable() -> String {
    answer(problem: problem("Focus a standard window to save its position"), commands: "")
  }
  let (windowError, window) = ax.focusedWindow()
  if windowError == .apiDisabled { return denied() }
  guard let window, !displays.isEmpty else { return unavailable() }
  let (fullScreenError, fullScreen) = ax.isFullScreen(window)
  if fullScreenError == .apiDisabled { return denied() }
  guard fullScreenError == .success, !fullScreen else { return unavailable() }
  let (frameError, frame) = ax.frame(window)
  if frameError == .apiDisabled { return denied() }
  guard frameError == .success, let frame, frame.width > 0, frame.height > 0,
    [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
  else { return unavailable() }

  let visible = displays[displayIndex(of: frame, in: displays)].visible
  guard visible.width > 0, visible.height > 0 else { return unavailable() }
  let gap = layout.gap(in: visible)
  let available = visible.insetBy(dx: gap, dy: gap)
  let rect = CGRect(
    x: (frame.minX - available.minX) / available.width, y: (frame.minY - available.minY) / available.height,
    width: frame.width / available.width, height: frame.height / available.height)
  let anchor = WindowAnchor.nearest(to: rect)
  func percent(_ size: CGFloat, span: CGFloat, alignment: CGFloat) -> Int {
    let bounds = Placement.percentages
    if size >= span - 2 * gap - 0.5 { return Int(bounds.upperBound) }
    // Undo the insets for this anchor so replay won't apply the gap to a size that already includes it.
    let insets = gap * (alignment == 0.5 ? 1 : 1.5)
    let result = ((size + insets) / span * 100).rounded()
    return Int(min(bounds.upperBound, max(bounds.lowerBound, result)))
  }
  let width = percent(frame.width, span: visible.width, alignment: anchor.position.x)
  let height = percent(frame.height, span: visible.height, alignment: anchor.position.y)
  let values = #"{"anchor":"\#(anchor.rawValue)","width":"\#(width)","height":"\#(height)"}"#
  return #"{"items":[],"actions":[{"type":"save","setting":"moves","values":\#(values)}]}"#
}

@MainActor func captureWindows(commandName: String, saving: Bool, layout: Layout) -> String {
  let workspace = NSWorkspace.shared
  let frontmost = workspace.frontmostApplication
  func bundleID(for app: NSRunningApplication) -> String? {
    guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
      bundleID != "app.wicket.Wicket", bundleID != "app.wicket.Wicket.dev",
      app.activationPolicy != .prohibited
    else { return nil }
    return bundleID
  }
  let displays = screenDisplays()
  if saving {
    guard let frontmost, bundleID(for: frontmost) != nil, !frontmost.isHidden else {
      return answer(problem: problem("Focus a standard window to save its position"), commands: "")
    }
    return saveCurrentWindow(
      SystemWindowAccessibility(pid: frontmost.processIdentifier),
      displays: displays, commandName: commandName, layout: layout)
  }
  let apps = workspace.runningApplications.compactMap { app -> CaptureApp<SystemWindowAccessibility>? in
    guard let bundleID = bundleID(for: app) else { return nil }
    return CaptureApp(
      bundleID: bundleID, hidden: app.isHidden,
      frontmost: app.processIdentifier == frontmost?.processIdentifier,
      ax: SystemWindowAccessibility(pid: app.processIdentifier, timeout: 0.25))
  }
  return captureWindows(apps, displays: displays, commandName: commandName)
}
