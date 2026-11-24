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
  _ apps: [CaptureApp<AX>], displays: [Display], commandName: String, saving: Bool = false
) -> String {
  let deadline = ContinuousClock.now + .seconds(7)
  func denied() -> String { answer(problem: accessibilityProblem(commandName), commands: "") }
  func timedOut() -> String {
    answer(
      problem: problem("Window capture timed out", "Close any unresponsive apps and try again"), commands: "")
  }
  var captured: [CapturedWindow] = []
  for app in apps where !app.hidden && (!saving || app.frontmost) {
    guard ContinuousClock.now < deadline else { return timedOut() }
    let ax = app.ax
    let (error, windows) = ax.windows(markFocused: app.frontmost)
    if error == .apiDisabled { return denied() }
    for (window, focused) in windows where !saving || focused {
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
  if saving {
    guard let window = captured.first else {
      return answer(problem: problem("Focus a standard window that fits within one display"), commands: "")
    }
    let rect = window.rect.map { String(Double($0)) }.joined(separator: ",")
    let definition =
      #"{"kind":"move","placement":{"display":"\#(window.display)","fallback":"current","rect":[\#(rect)],"gap":0}}"#
    return
      #"{"items":[],"actions":[{"type":"save","setting":"moves","values":{"definition":\#(quoted(definition))}}]}"#
  }
  guard let data = try? JSONEncoder().encode(captured) else {
    return answer(problem: problem("Couldn't encode captured windows"), commands: "")
  }
  return #"{"body":\#(quoted(String(decoding: data, as: UTF8.self)))}"#
}

@MainActor func captureWindows(commandName: String, saving: Bool = false) -> String {
  let workspace = NSWorkspace.shared
  let frontmost = workspace.frontmostApplication?.processIdentifier
  let apps = workspace.runningApplications.compactMap { app -> CaptureApp<SystemWindowAccessibility>? in
    guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
      bundleID != "app.wicket.Wicket", bundleID != "app.wicket.Wicket.dev",
      app.activationPolicy != .prohibited
    else { return nil }
    return CaptureApp(
      bundleID: bundleID, hidden: app.isHidden, frontmost: app.processIdentifier == frontmost,
      ax: SystemWindowAccessibility(pid: app.processIdentifier, timeout: 0.25))
  }
  return captureWindows(apps, displays: screenDisplays(), commandName: commandName, saving: saving)
}
