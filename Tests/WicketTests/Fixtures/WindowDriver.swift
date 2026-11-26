// Compiled as main.swift in the headless test, in place of the entry point that uses system AX.
import ApplicationServices
import Foundation

final class FakeAccessibility: WindowCaptureAccessibility {
  var current = CGRect(x: 520, y: 240, width: 240, height: 300)
  var hidden = false

  func windows(markFocused: Bool) -> (AXError, [(window: Int, focused: Bool)]) {
    precondition(!hidden, "Capture queried a hidden app")
    return (.success, (1...8).map { ($0, $0 == 1 && markFocused) })
  }
  func focusedWindow() -> (AXError, Int?) { (.success, 1) }
  func windowID(_ window: Int) -> CGWindowID? { CGWindowID(window) }
  func isStandard(_ window: Int) -> (AXError, Bool) { (.success, window != 3) }
  func isMinimized(_ window: Int) -> (AXError, Bool) { (.success, window == 4) }
  func isFullScreen(_ window: Int) -> (AXError, Bool) { (.success, window == 5) }
  func frame(_ window: Int) -> (AXError, CGRect?) {
    switch window {
    case 1: return (.success, current)
    case 2: return (.success, CGRect(x: -800, y: -100, width: 500, height: 440))
    case 6: return (.success, CGRect(x: -300, y: 100, width: 400, height: 400))
    case 7: return (.success, CGRect(x: 0, y: 10, width: 500, height: 500))
    case 8: return (.failure, nil)
    default: return (.success, current)
    }
  }
  func enhancedUserInterface() -> (AXError, Bool) { (.success, false) }
  func setEnhancedUserInterface(_ enabled: Bool) -> AXError { .success }
  func setPosition(_ position: CGPoint, of window: Int) -> AXError {
    current.origin = position
    return .success
  }
  func setSize(_ size: CGSize, of window: Int) -> AXError {
    current.size = size
    return .success
  }
}

let main = Display(
  frame: CGRect(x: 0, y: 0, width: 1040, height: 900), visible: CGRect(x: 0, y: 40, width: 1040, height: 800),
  uuid: UUID(uuidString: "12345678-1234-4321-1234-ABCDEFABCDEF"))
let external = Display(
  frame: CGRect(x: -1000, y: -200, width: 1000, height: 900),
  visible: CGRect(x: -1000, y: -180, width: 1000, height: 800),
  uuid: UUID(uuidString: "12345678-1234-4321-1234-FEDCBAFEDCBA"))
let displays = [main, external]

let ax = FakeAccessibility()
let frameFile = recordsFile.deletingLastPathComponent().appending(path: "mock-window-frame.json")
if let data = try? Data(contentsOf: frameFile),
  let current = try? JSONDecoder().decode(CGRect.self, from: data)
{
  ax.current = current
}
let hiddenApp = FakeAccessibility()
hiddenApp.hidden = true
if let view = windowAnswer(
  JSON.standardInput(), manifestBytes: contents("wicket.json") ?? [],
  move: { move, layout, name in
    let result = perform(
      move, layout: layout, pid: 42, name: "Editor", commandName: name, displays: displays,
      recordsFile: recordsFile, ax: ax)
    try! JSONEncoder().encode(ax.current).write(to: frameFile)
    return result
  },
  capture: { commandName, saving, layout in
    if saving { return saveCurrentWindow(ax, displays: displays, commandName: commandName, layout: layout) }
    return captureWindows(
      [
        CaptureApp(bundleID: "com.example.Editor", hidden: false, frontmost: true, ax: ax),
        CaptureApp(bundleID: "com.example.Hidden", hidden: true, frontmost: false, ax: hiddenApp),
      ],
      displays: displays, commandName: commandName)
  })
{
  print(view)
}
