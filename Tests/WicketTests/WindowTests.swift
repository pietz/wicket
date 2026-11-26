import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import WicketApp
@testable import window

// The bundled program only receives list requests here. Moves and Restore use fake Accessibility.

/// A 1512 × 982 main display whose menu bar takes 33 points and Dock 90, as NSScreen reports it (bottom
/// up), and a 1920 × 1080 display to its right, 298 points higher, with a 25-point menu bar.
private let mainHeight: CGFloat = 982
private let laptop = Display(
  frame: topDown(CGRect(x: 0, y: 0, width: 1512, height: 982), mainHeight: mainHeight),
  visible: topDown(CGRect(x: 0, y: 90, width: 1512, height: 859), mainHeight: mainHeight))
private let external = Display(
  frame: topDown(CGRect(x: 1512, y: 200, width: 1920, height: 1080), mainHeight: mainHeight),
  visible: topDown(CGRect(x: 1512, y: 200, width: 1920, height: 1055), mainHeight: mainHeight))

@Test func appKitScreensBecomeTopDownCoordinates() {
  #expect(laptop.frame == CGRect(x: 0, y: 0, width: 1512, height: 982))
  #expect(laptop.visible == CGRect(x: 0, y: 33, width: 1512, height: 859))
  #expect(external.frame == CGRect(x: 1512, y: -298, width: 1920, height: 1080))
  #expect(external.visible == CGRect(x: 1512, y: -273, width: 1920, height: 1055))
}

@Test func aWindowIsOnTheDisplayHoldingItsCenterElseTheOneItOverlapsMost() {
  let displays = [laptop, external]
  #expect(displayIndex(of: CGRect(x: 100, y: 100, width: 400, height: 300), in: displays) == 0)
  #expect(displayIndex(of: CGRect(x: 1400, y: 0, width: 600, height: 300), in: displays) == 1)
  // Its center in no display (below the external one, beside the laptop): the larger overlap wins.
  #expect(displayIndex(of: CGRect(x: 1450, y: 600, width: 1000, height: 800), in: displays) == 1)
  #expect(displayIndex(of: CGRect(x: 1400, y: 700, width: 300, height: 800), in: displays) == 0)
  #expect(displayIndex(of: CGRect(x: -5000, y: -5000, width: 10, height: 10), in: displays) == 0)
}

@Test(arguments: [
  (Move.left, CGRect(x: 0, y: 33, width: 756, height: 859)),
  (.right, CGRect(x: 756, y: 33, width: 756, height: 859)),
  (.maximize, CGRect(x: 0, y: 33, width: 1512, height: 859)),
  (.center, CGRect(x: 456, y: 162, width: 600, height: 600)),
])
func everyMoveFillsItsShareOfTheVisibleFrame(move: Move, expected: CGRect) {
  let current = CGRect(x: 10, y: 50, width: 600, height: 600)
  #expect(target(move, window: current, displays: [laptop, external])?.frame == expected)
}

@Test(arguments: [
  (Move.left, [1524, 1524, 1524]),
  (.right, [2478, 2158, 2798]),
])
func stockSidesCycleThroughWidthsOnTheWindowsDisplay(move: Move, origins: [Int]) {
  let layout = Layout(gap: "12")
  let displays = [laptop, external]
  let frames = zip(origins, [942, 1262, 622]).map { x, width in
    CGRect(x: x, y: -261, width: width, height: 1031)
  }
  let floating = CGRect(x: 2000, y: 0, width: 600, height: 500)
  for (current, expected) in zip([floating] + frames, frames + frames.prefix(1)) {
    #expect(target(move, window: current, displays: displays, layout: layout)?.frame == expected)
  }
  // Keep the outer and vertical edges within tolerance as well as the size.
  let half = frames[0]
  let rounded = half.insetBy(dx: 7, dy: 9)
  #expect(target(move, window: rounded, displays: displays, layout: layout)?.frame == frames[1])
  for misplaced in [half.offsetBy(dx: 25, dy: 0), half.insetBy(dx: 0, dy: 25)] {
    #expect(target(move, window: misplaced, displays: displays, layout: layout)?.frame == half)
  }
}

@Test(arguments: [window.WindowAnchor.left, .right])
func aSideWidthBetweenPresetsCanWrapWhenAnAppClampsItsSize(anchor: window.WindowAnchor) {
  func aligned(_ width: CGFloat) -> CGRect {
    let x = anchor == .left ? 0 : laptop.visible.maxX - width
    return CGRect(x: x, y: 33, width: width, height: 859)
  }
  #expect(sideTarget(anchor, window: aligned(514), visible: laptop.visible, gap: 0) == aligned(756))
  #expect(sideTarget(anchor, window: aligned(620), visible: laptop.visible, gap: 0) == aligned(756))
  #expect(sideTarget(anchor, window: aligned(800), visible: laptop.visible, gap: 0) == aligned(1008))
}

@Test func sideMovesSkipWidthsThatLeaveNoRoomForTheGap() {
  let visible = CGRect(x: 0, y: 40, width: 800, height: 1000)
  let half = CGRect(x: 200, y: 240, width: 100, height: 600)
  let wider = CGRect(x: 200, y: 240, width: 233, height: 600)
  #expect(sideTarget(.left, window: half, visible: visible, gap: 200) == wider)
  #expect(sideTarget(.left, window: wider, visible: visible, gap: 200) == half)
}

@Test(arguments: [
  (window.WindowAnchor.bottomRight, CGSize(width: 180, height: 150), CGPoint(x: 10, y: 440)),
  (.bottomRight, CGSize(width: 300, height: 250), CGPoint(x: -110, y: 340)),
  (.bottomRight, CGSize(width: 550, height: 390), CGPoint(x: -360, y: 200)),
  (.topLeft, CGSize(width: 550, height: 390), CGPoint(x: -390, y: 210)),
  (.topLeft, CGSize(width: 600, height: 400), CGPoint(x: -400, y: 200)),
  (.center, CGSize(width: 300, height: 250), CGPoint(x: -250, y: 275)),
  (.center, CGSize(width: 650, height: 450), CGPoint(x: -425, y: 175)),
])
func aConstrainedSizeKeepsTheMovesAnchor(anchor: window.WindowAnchor, size: CGSize, expected: CGPoint) throws
{
  let visible = CGRect(x: -400, y: 200, width: 600, height: 400)
  let frame = try #require(Placement(anchor: anchor, width: 50, height: 50).frame(in: visible, gap: 10))
  let destination = WindowTarget(frame: frame, visible: visible, alignment: anchor.position)
  #expect(destination.position(for: size) == expected)
}

@Test func halvesCoverAnOddScreenWithoutAGapAndCenterKeepsTheWindowOnIt() throws {
  let odd = Display(
    frame: CGRect(x: 0, y: 0, width: 1511, height: 981),
    visible: CGRect(x: 0, y: 25, width: 1511, height: 901))
  let current = CGRect(x: 0, y: 0, width: 2000, height: 300)
  let left = try #require(target(.left, window: current, displays: [odd])?.frame)
  let right = try #require(target(.right, window: current, displays: [odd])?.frame)
  #expect(left.maxX == right.minX && right.maxX == 1511)
  let top = try #require(Placement(anchor: .top, width: 100, height: 50).frame(in: odd.visible, gap: 0))
  let bottom = try #require(Placement(anchor: .bottom, width: 100, height: 50).frame(in: odd.visible, gap: 0))
  #expect(top.maxY == bottom.minY && bottom.maxY == 926)
  // A window wider than the screen is centered at the screen's width.
  #expect(
    target(.center, window: current, displays: [odd])?.frame == CGRect(x: 0, y: 325, width: 1511, height: 300)
  )
}

@Test func moveSucceedsOnTheWindowsOwnDisplay() {
  let onExternal = CGRect(x: 2000, y: 0, width: 800, height: 600)
  #expect(
    target(.left, window: onExternal, displays: [laptop, external])?.frame
      == CGRect(x: 1512, y: -273, width: 960, height: 1055))
  #expect(target(.maximize, window: onExternal, displays: [laptop, external])?.frame == external.visible)
}

@Test func nextDisplayKeepsThePlaceAndShareOfTheScreenAndWrapsAround() throws {
  let displays = [laptop, external]
  // A left half stays a left half.
  let leftHalf = try #require(target(.left, window: .zero, displays: [laptop])?.frame)
  #expect(
    target(.nextDisplay, window: leftHalf, displays: displays)?.frame
      == CGRect(x: 1512, y: -273, width: 960, height: 1055))
  // From the rightmost display back to the first.
  let maximized = external.visible
  #expect(target(.nextDisplay, window: maximized, displays: displays)?.frame == laptop.visible)
  // A small window keeps its relative place, scaled, and never crosses the edges.
  let small = CGRect(x: 1512 + 1700, y: -273, width: 400, height: 300)
  let moved = try #require(target(.nextDisplay, window: small, displays: displays)?.frame)
  #expect(moved.width == 315 && moved.height == 244 && laptop.visible.contains(moved))
  #expect(target(.nextDisplay, window: leftHalf, displays: [laptop]) == nil)
  // Three displays in the order they stand, left to right, whatever order AppKit lists them in.
  let left = Display(
    frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
    visible: CGRect(x: -1440, y: 25, width: 1440, height: 875))
  let order = [external, laptop, left]
  #expect(target(.nextDisplay, window: left.visible, displays: order)?.frame == laptop.visible)
  #expect(target(.nextDisplay, window: laptop.visible, displays: order)?.frame == external.visible)
  #expect(target(.nextDisplay, window: external.visible, displays: order)?.frame == left.visible)
}

@Test func restoreAndAnEmptyScreenListGiveNoTarget() {
  #expect(target(.restore, window: .zero, displays: [laptop]) == nil)
  #expect(target(.maximize, window: .zero, displays: []) == nil)
}

// MARK: - Restore

@Test func restoreUndoesTheLastMovesOfThisWindowInTurn() throws {
  let original = CGRect(x: 100.5, y: 200, width: 640, height: 480)
  let half = CGRect(x: 0, y: 33, width: 756, height: 859)
  // A terminal snapped the maximized window to its grid: the record has where it ended up.
  let maximized = CGRect(x: 0, y: 33, width: 1508, height: 855)
  let other = Record(pid: 7, before: .zero, after: half)
  var records = window.parse(
    records: window.format([
      Record(pid: 42, before: original, after: half), other,
      Record(pid: 42, before: half, after: maximized),
    ]) + "garbage line\n42 1 2 3\n")
  #expect(records.count == 3)
  // Within a point of where Wicket left it.
  var index = try #require(restoreIndex(records, pid: 42, frame: maximized.offsetBy(dx: 1, dy: 0)))
  #expect(records.remove(at: index).before == half)
  index = try #require(restoreIndex(records, pid: 42, frame: half))
  #expect(records.remove(at: index).before == original)
  #expect(restoreIndex(records, pid: 42, frame: original) == nil)
  // Moved by hand since, or another app's window: nothing to restore.
  #expect(restoreIndex(records, pid: 7, frame: half.offsetBy(dx: 2, dy: 0)) == nil)
  #expect(restoreIndex(records, pid: 8, frame: half) == nil)
  #expect(records == [other])
}

// MARK: - Frame writes

private final class FakeWindowAccessibility: WindowAccessibility {
  enum Event: Equatable {
    case readFrame
    case enhanced(Bool)
    case size, position
  }

  static let original = CGRect(x: 100, y: 200, width: 640, height: 480)
  var current = original
  var enhanced = false
  var applyPosition = true
  var applySize = true
  var adjustedSize: CGSize?
  var minimumWidth: CGFloat = 0
  var sizeBeforePosition: CGSize?
  var trailingLimit: CGFloat?
  var positionError = AXError.success
  var sizeError = AXError.success
  var focusError = AXError.success
  var readbackErrors: [AXError] = []
  var reenableErrors: [AXError] = []
  var events: [Event] = []

  func focusedWindow() -> (AXError, Int?) {
    (focusError, focusError == .success ? 1 : nil)
  }
  func isFullScreen(_ window: Int) -> (AXError, Bool) { (.success, false) }
  func frame(_ window: Int) -> (AXError, CGRect?) {
    let error =
      events.contains(.position) && !readbackErrors.isEmpty ? readbackErrors.removeFirst() : .success
    events.append(.readFrame)
    return (error, error == .success ? current : nil)
  }
  func enhancedUserInterface() -> (AXError, Bool) { (.success, enhanced) }
  func setEnhancedUserInterface(_ enabled: Bool) -> AXError {
    events.append(.enhanced(enabled))
    let error = enabled && !reenableErrors.isEmpty ? reenableErrors.removeFirst() : .success
    if error == .success { enhanced = enabled }
    return error
  }
  func setPosition(_ position: CGPoint, of window: Int) -> AXError {
    events.append(.position)
    if !enhanced, applyPosition, positionError == .success { current.origin = position }
    return positionError
  }
  func setSize(_ size: CGSize, of window: Int) -> AXError {
    events.append(.size)
    if !enhanced, applySize, sizeError == .success {
      let available = trailingLimit.map { $0 - current.minX } ?? size.width
      let achievable = CGSize(width: max(min(available, size.width), minimumWidth), height: size.height)
      let beforePosition = events.contains(.position) ? nil : sizeBeforePosition
      current.size = beforePosition ?? adjustedSize ?? achievable
    }
    return sizeError
  }

  func move(_ move: Move, in folder: URL, commandName: String = "Windows") throws -> Row? {
    try apply(.stock(move), in: folder, commandName: commandName)
  }

  func apply(
    _ move: WindowMove, in folder: URL, commandName: String = "Windows", layout: Layout = Layout(),
    displays: [Display] = [laptop]
  ) throws -> Row? {
    events.removeAll()
    let failure = perform(
      move, layout: layout, pid: 42, name: "Test App", commandName: commandName, displays: displays,
      recordsFile: folder.appending(path: "moves.txt"), ax: self)
    guard let failure else { return nil }
    return try JSONDecoder().decode(Row.self, from: Data(failure.utf8))
  }
}

private func moveRecords(in folder: URL) throws -> [Record] {
  window.parse(records: try String(contentsOf: folder.appending(path: "moves.txt"), encoding: .utf8))
}

@Test func settersThatSilentlyIgnoreTheMoveGiveAFailureAndNoRecord() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.applyPosition = false
  ax.applySize = false
  #expect(try ax.move(.left, in: folder)?.title == "Test App's window can't be moved")
  #expect(ax.events == [.readFrame, .size, .readFrame, .position, .size, .readFrame, .position, .readFrame])
  #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "moves.txt").path))
}

@Test func anOverlappingMoveLeavesTheFirstMovesAccessibilityStateAlone() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let lock = open(folder.appending(path: "moves.txt.lock").path, O_RDWR | O_CREAT, 0o600)
  try #require(lock >= 0)
  defer { close(lock) }
  try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
  let ax = FakeWindowAccessibility()
  ax.enhanced = true
  #expect(try ax.move(.left, in: folder)?.title == "Another window move is in progress")
  #expect(ax.events.isEmpty && ax.enhanced)
}

@Test(arguments: [752, 776])
func stockMovesAcceptGridSnappingAndModestMinimumWidths(width: Int) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  // Left Half asks for 756 points. A terminal can snap to 752, or an app can require 776.
  let adjusted = CGRect(x: 0, y: 33, width: width, height: 859)
  ax.adjustedSize = adjusted.size
  let first = try ax.move(.left, in: folder)
  #expect(first == nil, "\(first?.title ?? "")")
  #expect(ax.current == adjusted)
  ax.adjustedSize = nil
  let repeated = try ax.move(.left, in: folder)
  #expect(repeated == nil, "\(repeated?.title ?? "")")
  #expect(ax.current == CGRect(x: 0, y: 33, width: 1008, height: 859))
  #expect(
    try moveRecords(in: folder) == [
      Record(pid: 42, before: FakeWindowAccessibility.original, after: ax.current, cycle: .left)
    ])

  let restored = try ax.move(.restore, in: folder)
  #expect(restored == nil, "\(restored?.title ?? "")")
  #expect(ax.current == FakeWindowAccessibility.original)
}

@Test(arguments: [Move.left, .right])
func restoreUndoesACompleteWidthCycleInOneMove(side: Move) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  let original = ax.current
  for width in [756, 1008, 504, 756] {
    #expect(try ax.move(side, in: folder) == nil)
    let x = side == .left ? 0 : 1512 - width
    #expect(ax.current == CGRect(x: x, y: 33, width: width, height: 859))
    #expect(
      try moveRecords(in: folder) == [Record(pid: 42, before: original, after: ax.current, cycle: side)])
  }
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == original)
  #expect(try moveRecords(in: folder).isEmpty)
}

@Test(arguments: [620, 800])
func aRightCycleKeepsItsAnchorAndContinuesAfterAMinimumWidth(minimum: Int) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  let starting = CGRect(x: 100, y: 200, width: 900, height: 480)
  ax.current = starting
  ax.minimumWidth = CGFloat(minimum)
  let layout = Layout(gap: "12")
  for width in [max(minimum, 738), 990, minimum, minimum > 738 ? 990 : 738] {
    _ = try ax.apply(.stock(.right), in: folder, layout: layout)
    #expect(ax.current == CGRect(x: 1500 - width, y: 45, width: width, height: 835))
  }
  #expect(
    try moveRecords(in: folder) == [Record(pid: 42, before: starting, after: ax.current, cycle: .right)])
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == starting)
}

@Test func aSavedHalfStaysFixedAndStartsItsOwnRestoreStepBeforeAStockCycle() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  let original = ax.current
  let saved = WindowMove.custom(Placement(anchor: .left, width: 50, height: 100))
  for _ in 1...2 { #expect(try ax.apply(saved, in: folder) == nil) }
  let half = CGRect(x: 0, y: 33, width: 756, height: 859)
  #expect(ax.current == half)
  #expect(try ax.move(.left, in: folder) == nil)
  #expect(ax.current.width == 1008)
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == half)
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == original)
}

@Test func aRightHalfCanGrowWhenItsOldOriginLimitsTheFirstResize() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.current = CGRect(x: 756, y: 33, width: 756, height: 859)
  ax.trailingLimit = laptop.visible.maxX
  #expect(try ax.move(.right, in: folder) == nil)
  #expect(ax.current == CGRect(x: 504, y: 33, width: 1008, height: 859))
}

@Test func aSavedMoveAnchorsAFixedSizeFromReadback() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.applySize = false
  let saved = WindowMove.custom(Placement(anchor: .bottomRight, width: 30, height: 30))
  let result = try ax.apply(saved, in: folder, layout: Layout(gap: "12"))
  #expect(result?.title == "Test App's window only moved partway")
  #expect(ax.current == CGRect(x: 860, y: 400, width: 640, height: 480))
}

@Test func nextDisplayReanchorsAfterTheSizeChangesOnTheDestination() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.current = CGRect(x: 756, y: 33, width: 756, height: 859)
  ax.sizeBeforePosition = CGSize(width: 1024, height: 1200)
  #expect(try ax.apply(.stock(.nextDisplay), in: folder, displays: [laptop, external]) == nil)
  #expect(ax.current == CGRect(x: 2472, y: -273, width: 960, height: 1055))
  #expect(ax.events == [.readFrame, .size, .readFrame, .position, .size, .readFrame, .position, .readFrame])
}

@Test func aRefusedResizeThatLeavesAnEdgeFarFromTheTargetIsPartial() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  let original = CGRect(x: 100, y: 33, width: 900, height: 859)
  ax.current = original
  ax.applySize = false
  #expect(try ax.move(.left, in: folder)?.title == "Test App's window only moved partway")
  let partial = CGRect(x: 0, y: 33, width: 900, height: 859)
  #expect(ax.current == partial)
  #expect(try ax.move(.left, in: folder)?.title == "Test App's window can't be moved")
  #expect(try moveRecords(in: folder) == [Record(pid: 42, before: original, after: partial, cycle: .left)])
}

@Test(arguments: [0, 1, 2])
func enhancedInterfaceStaysOffThroughReadbackAndIsRestoredAfterward(readbackFailures: Int) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.enhanced = true
  ax.readbackErrors = Array(repeating: .cannotComplete, count: readbackFailures)
  let result = try ax.move(.left, in: folder)
  #expect(ax.current == target(.left, window: FakeWindowAccessibility.original, displays: [laptop])?.frame)
  #expect(ax.enhanced)
  let reads: [FakeWindowAccessibility.Event] =
    readbackFailures == 0 ? [.readFrame] : [.readFrame, .readFrame]
  #expect(
    ax.events == [.readFrame, .enhanced(false), .size, .readFrame, .position, .size] + reads + [
      .enhanced(true)
    ])
  if readbackFailures == 2 {
    #expect(result?.title == "Couldn't verify Test App's final window position")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "moves.txt").path))
  } else {
    #expect(result == nil)
    #expect(
      try moveRecords(in: folder) == [
        Record(pid: 42, before: FakeWindowAccessibility.original, after: ax.current, cycle: .left)
      ])
  }
}

@Test(arguments: [AXError.success, .cannotComplete, .apiDisabled])
func enhancedInterfaceCleanupRetriesATimeoutAndReportsFailure(resultOfRetry: AXError) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.enhanced = true
  ax.reenableErrors = [.cannotComplete, resultOfRetry]
  let result = try ax.move(.left, in: folder)
  #expect(ax.current == target(.left, window: FakeWindowAccessibility.original, displays: [laptop])?.frame)
  #expect(ax.events.suffix(3) == [.readFrame, .enhanced(true), .enhanced(true)])
  #expect(ax.enhanced == (resultOfRetry == .success))
  if resultOfRetry == .success {
    #expect(result == nil)
  } else {
    #expect(result?.title == "Couldn't re-enable Enhanced User Interface for Test App")
    if resultOfRetry == .apiDisabled {
      #expect(result?.actions.map(\.kind) == [.open(Permission.accessibility.pane)])
    }
  }
  #expect(
    try moveRecords(in: folder) == [
      Record(pid: 42, before: FakeWindowAccessibility.original, after: ax.current, cycle: .left)
    ])
}

@Test func restoreUsesTheObservedPartialMoveAndCanRetryAPartialRestore() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  let original = ax.current
  ax.positionError = .cannotComplete
  #expect(try ax.move(.left, in: folder)?.title == "Test App's window only moved partway")
  #expect(ax.events.last == .readFrame)
  let partial = ax.current
  #expect(partial.origin == original.origin && partial.size != original.size)
  let history = try String(contentsOf: folder.appending(path: "moves.txt"), encoding: .utf8)
  try #require(
    window.parse(records: history) == [Record(pid: 42, before: original, after: partial, cycle: .left)],
    "\(history)")

  ax.positionError = .success
  #expect(try ax.move(.maximize, in: folder) == nil)
  ax.sizeError = .failure
  #expect(try ax.move(.restore, in: folder)?.subtitle == "Try Restore again")
  #expect(ax.current.origin == partial.origin && ax.current.size != partial.size)
  #expect(try moveRecords(in: folder).last == Record(pid: 42, before: partial, after: ax.current))

  ax.sizeError = .success
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == partial)
  #expect(try ax.move(.restore, in: folder) == nil)
  #expect(ax.current == original)
  #expect(try moveRecords(in: folder).isEmpty)
  #expect(try ax.move(.restore, in: folder)?.title == "Nothing to restore")
}

// MARK: - The program and its documentation

private func windowView(_ action: String? = nil, submitted: Bool = false) async throws
  -> ProviderView
{
  try await runBundled(
    "window", request: ProviderRequest(input: "", action: action, submitted: submitted))
}

@Test func theItemsAreTheMovesAndTheProgramListsThemWithoutMoving() async throws {
  let manifest = try bundled("window").manifest
  #expect(manifest.name == "Windows" && manifest.keyword == "window")
  #expect(!manifest.matches("window"))
  let rows = try #require(manifest.items)
  #expect(rows.map(\.id) == Move.allCases.map(\.rawValue) + ["save-current"])
  for row in rows {
    guard case .run(let address) = row.actions.first?.kind else {
      Issue.record("\(row.id) runs no move")
      continue
    }
    #expect(address.extensionName == nil && address.action == row.id && row.actions.count == 1)
  }
  // Requests that are not submitted, and the submitted one that enters the command, list the same items.
  #expect(try await windowView().items == rows)
  #expect(try await windowView("left").items == rows)
  #expect(try await windowView(submitted: true).items == rows)
  #expect(
    try await windowView("sideways", submitted: true).items.first?.title == "Window move is unavailable")
}

/// A move that failed answers one row saying why: the whole answer, so no command that matches what is
/// typed ranks above it, and its first line, which an open panel shows alone, says what happened.
@Test func aFailedMoveAnswersOnlyTheRowThatSaysWhy() throws {
  let view = try JSONDecoder().decode(
    ProviderView.self,
    from: Data(
      answer(problem: problem("No window to move"), commands: #"{"id":"left","title":"Left Half"}"#).utf8))
  #expect(view.items.map(\.title) == ["No window to move"])
}

/// Wicket checks Accessibility before running the program: without it the command answers Wicket's row,
/// which opens the pane and says what to do when Wicket's switch is already on, and no move runs.
@MainActor @Test func withoutAccessibilityWicketAnswersForTheWindowCommands() async throws {
  let window = try bundled("window")
  #expect(window.manifest.permissions == [.accessibility])
  let host = ExtensionHost(folder: URL(filePath: "/nonexistent"), bundled: bundledExtensions)
  host.permissions = Permissions(status: { _ in .denied }, request: { _ in })
  let view = try await host.view(
    window, request: ProviderRequest(input: "", action: "left", submitted: true))
  let row = try #require(view.items.first)
  #expect(view.items.count == 1 && row.title == "Allow Accessibility for Wicket")
  #expect(row.subtitle == "Windows needs it. If on, remove (–) and re-add Wicket.")
  #expect(row.actions.map(\.kind) == [.open(Permission.accessibility.pane)])
}

@MainActor @Test(arguments: [false, true])
func apiDisabledOffersTheSameRecoveryAsTheHost(duringWrite: Bool) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  if duringWrite {
    ax.enhanced = true
    ax.positionError = .apiDisabled
  } else {
    ax.focusError = .apiDisabled
  }
  let command = try bundled("window")
  let permissions = Permissions(status: { _ in .denied }, request: { _ in })
  let gate = try #require(permissions.gate(command, rerun: Address(extensionName: "window")))
  let hostRow = try #require(gate.items.first)
  let row = try #require(try ax.move(.left, in: folder, commandName: command.manifest.name))
  #expect(row.title == hostRow.title && row.subtitle == hostRow.subtitle)
  #expect(row.actions == hostRow.actions)
  if duringWrite {
    #expect(ax.events.suffix(2) == [.readFrame, .enhanced(true)])
  }
}

@Test func theDocsNameEveryWindowCommand() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let rows = try #require(try bundled("window").manifest.items)
  for file in ["README.md", "docs/manual-checks.md"] {
    let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
    let missing = rows.map(\.title).filter { !text.contains($0) }
    #expect(missing.isEmpty, "\(file) does not name \(missing)")
  }
}

// MARK: - Settings

@Test func stockAndCustomMovesShareTheSameEvenGaps() throws {
  // An odd visible width centered on the global origin exercises rounding on both sides of zero.
  let screen = CGRect(x: -756, y: 33, width: 1511, height: 859)
  let display = Display(frame: screen, visible: screen)
  let current = CGRect(x: 10, y: 50, width: 600, height: 600)
  for gap in [8.0, 9.0] {
    let layout = Layout(gap: String(gap))
    func moved(_ move: Move) throws -> CGRect {
      try #require(target(move, window: current, displays: [display], layout: layout)?.frame)
    }
    #expect(try moved(.maximize) == screen.insetBy(dx: gap, dy: gap))
    let (left, right) = (try moved(.left), try moved(.right))
    #expect(left.minX == screen.minX + gap && right.minX - left.maxX == gap)
    #expect(right.maxX == screen.maxX - gap && left.height == screen.height - 2 * gap)
    #expect(Placement(anchor: .left, width: 50, height: 100).frame(in: screen, gap: gap) == left)
    let top = try #require(Placement(anchor: .top, width: 100, height: 50).frame(in: screen, gap: gap))
    let bottom = try #require(Placement(anchor: .bottom, width: 100, height: 50).frame(in: screen, gap: gap))
    #expect(bottom.minY - top.maxY == gap && bottom.maxY == screen.maxY - gap)
    let center = try #require(Placement(anchor: .center, width: 60, height: 80).frame(in: screen, gap: gap))
    #expect(abs(center.width - (screen.width * 0.6 - gap)) <= 1)
    #expect(abs(center.height - (screen.height * 0.8 - gap)) <= 1)
    #expect(abs(center.midX - screen.midX) <= 0.5 && abs(center.midY - screen.midY) <= 0.5)
  }
}

@Test func gapSettingsRejectInvalidValuesAndClampOnSmallDisplays() {
  #expect(Layout() == Layout(gap: "0"))
  #expect(Layout(gap: "wide") == Layout())
  #expect(Layout(gap: "-4") == Layout())
  #expect(Layout(gap: "201") == Layout())
  #expect(Layout(gap: "12.4").gap == 12)
  let small = CGRect(x: 0, y: 20, width: 320, height: 200)
  #expect(Layout(gap: "200").gap(in: small) == 50)
  #expect(Placement(anchor: .center, width: 10, height: 10).frame(in: small, gap: 50) == nil)
}

@Test(arguments: [
  (window.WindowAnchor.topLeft, -1300, -180),
  (.top, -940, -180),
  (.topRight, -580, -180),
  (.left, -1300, 45),
  (.center, -940, 45),
  (.right, -580, 45),
  (.bottomLeft, -1300, 270),
  (.bottom, -940, 270),
  (.bottomRight, -580, 270),
])
func anchoredMovesResolveAgainstTheVisibleFrame(anchor: window.WindowAnchor, x: Int, y: Int) throws {
  let visible = CGRect(x: -1300, y: -180, width: 1200, height: 900)
  let rect = try #require(Placement(anchor: anchor, width: 40, height: 50).frame(in: visible, gap: 0))
  #expect(rect == CGRect(x: x, y: y, width: 480, height: 450))
  let normalized = CGRect(
    x: (CGFloat(x) - visible.minX) / visible.width, y: (CGFloat(y) - visible.minY) / visible.height,
    width: 0.4, height: 0.5)
  #expect(window.WindowAnchor.nearest(to: normalized) == anchor)
}

@Test func thirdsAndTwoThirdsUseTheSameGutter() throws {
  let screen = CGRect(x: -900, y: 30, width: 900, height: 600)
  let left = try #require(Placement(anchor: .left, width: 66.67, height: 100).frame(in: screen, gap: 12))
  let right = try #require(Placement(anchor: .right, width: 33.33, height: 100).frame(in: screen, gap: 12))
  #expect(left == CGRect(x: -888, y: 42, width: 582, height: 576))
  #expect(right == CGRect(x: -294, y: 42, width: 282, height: 576))

  let full = CGRect(x: 0, y: 0, width: 1000, height: 800)
  let third = try #require(Placement(anchor: .left, width: 33.3, height: 100).frame(in: full, gap: 9))
  let remainder = try #require(Placement(anchor: .right, width: 66.7, height: 100).frame(in: full, gap: 9))
  #expect(remainder.minX - third.maxX == 9)
}

@Test func subpointRoundingStaysInsideTheVisibleFrame() throws {
  let visible = CGRect(x: -1300.3, y: -180.2, width: 1200.7, height: 900.1)
  let rect = try #require(Placement(anchor: .center, width: 100, height: 100).frame(in: visible, gap: 0))
  #expect(visible.contains(rect))
  #expect(rect == CGRect(x: -1300, y: -180, width: 1200, height: 899))
}

// MARK: - Saved moves and Capture

@MainActor
@Test(arguments: [
  [:],
  ["anchor": "anywhere", "width": "50", "height": "100"],
  ["anchor": "left", "width": "9", "height": "100"],
  ["anchor": "left", "width": "50", "height": "101"],
  ["anchor": "left", "width": "nan", "height": "100"],
  ["anchor": "left", "width": "50", "height": ""],
])
func invalidWindowPlacementsGiveAClearRowWithoutTouchingWindows(fields: [String: String]) throws {
  let request: window.JSON = .object([
    "submitted": .bool(true), "action": .string("apply-placement"),
    "fields": .object(fields.mapValues(window.JSON.string)),
  ])
  let answer = windowAnswer(
    request, manifestBytes: [],
    move: { _, _, _ in
      Issue.record("Invalid move reached the window adapter")
      return nil
    },
    capture: { _, _, _ in
      Issue.record("Invalid move reached capture")
      return ""
    })
  let response = try #require(answer)
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(response.utf8))
  #expect(view.items.first?.title == "Invalid window move")
  #expect(view.items.first?.subtitle == "Choose an anchor and enter width and height from 10 to 100%")
}

@Test func anOversizeWindowCaptureClampsItsPercentagesOnItsOwnDisplay() throws {
  let ax = FakeWindowAccessibility()
  ax.current = CGRect(x: 1490, y: -300, width: 1950, height: 50)
  let response = saveCurrentWindow(
    ax, displays: [laptop, external], commandName: "Windows", layout: Layout())
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(response.utf8))
  #expect(
    view.actions.first?.kind
      == .save(setting: "moves", values: ["anchor": "top", "width": "100", "height": "10"]))
}

@Test func capturingTiledWindowsDoesNotApplyTheGapTwice() throws {
  let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
  let screens = [Display(frame: visible, visible: visible)]
  let layout = Layout(gap: "20")
  let ax = FakeWindowAccessibility()
  for original in [
    Placement(anchor: .left, width: 50, height: 100),
    Placement(anchor: .center, width: 60, height: 80),
    Placement(anchor: .bottomRight, width: 40, height: 30),
  ] {
    ax.current = try #require(original.frame(in: visible, gap: layout.gap))
    let response = saveCurrentWindow(ax, displays: screens, commandName: "Windows", layout: layout)
    let view = try JSONDecoder().decode(ProviderView.self, from: Data(response.utf8))
    guard case .save("moves", let values) = view.actions.first?.kind else {
      Issue.record("Capture didn't provide move fields")
      continue
    }
    let saved = try #require(Placement(fields: .object(values.mapValues(window.JSON.string))))
    #expect(
      saved.anchor == original.anchor && saved.width == original.width && saved.height == original.height)
    #expect(saved.frame(in: visible, gap: layout.gap) == ax.current)
  }
}

/// Use the same request dispatcher and move engine in the spawned child, with an in-memory AX adapter.
private func installFakeWindowManager(in root: URL) throws -> URL {
  let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/Extensions/window")
  let fixture = try #require(Bundle.module.url(forResource: "Fixtures/WindowDriver", withExtension: "swift"))
  let manifestFile = source.appending(path: "wicket.json")
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
  manifest["permissions"] = nil  // All AX calls in the driver go to the fake.
  let folder = try extensionFolder(root, name: "window", fields: manifest)
  let entry = root.appending(path: "main.swift")
  try FileManager.default.copyItem(at: fixture, to: entry)
  let compiler = Process()
  compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  compiler.arguments =
    ["swiftc", "-swift-version", "6", "-warnings-as-errors", entry.path]
    + ["Window", "WindowAnchor", "Placement", "Capture", "JSON"].map {
      source.appending(path: $0 + ".swift").path
    }
    + ["-o", folder.appending(path: "main").path]
  try compiler.run()
  compiler.waitUntilExit()
  try #require(compiler.terminationStatus == 0)
  return folder
}

let codingMove = [
  "id": "coding", "title": "Coding layout",
  "anchor": "left", "width": "50", "height": "100",
]

@MainActor @Test func captureBecomesAHeadlessMoveAndAnEntryHotkey() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let folder = try await Task.detached { try installFakeWindowManager(in: root) }.value
  let history = Edition.current.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": root.path])
  let (captureStatus, capture) = try await cli(
    root, ["--extension", "window", "--submitted", "--action", "capture"])
  #expect(captureStatus == 0)
  let body = try #require(capture["body"].string)
  struct Entry: Decodable, Equatable {
    let bundleID: String
    let display: String
    let rect: [Double]
    let focused: Bool
  }
  let entries = try JSONDecoder().decode([Entry].self, from: Data(body.utf8))
  #expect(
    entries == [
      Entry(
        bundleID: "com.example.Editor", display: "12345678-1234-4321-1234-ABCDEFABCDEF",
        rect: [0.5, 0.25, 240.0 / 1040, 0.375], focused: true),
      Entry(
        bundleID: "com.example.Editor", display: "12345678-1234-4321-1234-FEDCBAFEDCBA",
        rect: [0.2, 0.1, 0.5, 0.55], focused: false),
    ])
  let dataFolder = try #require(
    FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first)
  let frameFile = dataFolder.appending(path: "mock-window-frame.json")
  let original = CGRect(x: -800, y: -100, width: 500, height: 440)
  let captured = CGRect(x: 520, y: 240, width: 240, height: 300)
  let destination = CGRect(x: -615, y: 68, width: 230, height: 304)
  func observedFrame() throws -> CGRect {
    try JSONDecoder().decode(CGRect.self, from: Data(contentsOf: frameFile))
  }
  // Capture on the main display, then move the window to the external display before replay.
  try JSONEncoder().encode(captured).write(to: frameFile)
  let (saveStatus, save) = try await cli(
    root, ["--extension", "window", "--submitted", "--action", "save-current"])
  let saveAction = try #require(save["actions"].array.first)
  #expect(saveStatus == 0 && saveAction["type"].string == "save" && saveAction["setting"].string == "moves")
  guard case .object(let savedFields) = saveAction["values"] else {
    throw ExtensionFailure("Capture didn't provide move fields")
  }
  let placement = savedFields.compactMapValues(\.string)
  #expect(placement == ["anchor": "center", "width": "23", "height": "38"])
  try JSONEncoder().encode(original).write(to: frameFile)
  let entry = codingMove.merging(placement) { _, captured in captured }
  try saveProviders([.init("extension:window")], in: root)
  try ConfigurationFile(url: root.appending(path: "config.json")).set(
    "window", to: ["moves": [entry]], in: "extensions")
  let (queryStatus, query) = try await cli(root, ["--query", "Coding"])
  #expect(
    queryStatus == 0 && query["items"].array.contains { $0["row"]["id"].string == "entry:moves/coding" })
  #expect(try observedFrame() == original)

  let target = try #require(HotkeyTarget("wicket://window?entry=moves/coding"))
  let action = Address(fields: placement, action: "apply-placement", hidden: true)
  let fields = String(decoding: try JSONEncoder().encode(action.fields), as: UTF8.self)
  let status = try await cli(
    root,
    [
      "--extension", "window", "--submitted", "--action",
      try #require(action.action), "--fields", fields,
    ])
  #expect(status.0 == 0 && status.1 == .object([:]))
  #expect(try observedFrame() == destination)
  #expect(try moveRecords(in: dataFolder) == [Record(pid: 42, before: original, after: destination)])
  let restore = try await cli(root, ["--extension", "window", "--submitted", "--action", "restore"])
  #expect(restore.0 == 0 && restore.1 == .object([:]))
  #expect(try observedFrame() == original)

  let bundled = root.appending(path: "bundled")
  let bundledWindow = bundled.appending(path: "window")
  try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
  try FileManager.default.moveItem(at: folder, to: bundledWindow)
  _ = try extensionFolder(root, name: "window", fields: ["contract": 1])
  let model = LauncherModel(
    history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: bundled,
    extensionDataDirectory: history)
  model.store.start(watching: false)
  await model.extensions.reload()
  #expect(model.extensions.problems["extension:window"]?.usingBundled == true)
  let surface = RecordingSurface()
  surface.shown = false
  model.navigator.surface = surface
  model.store.bind(try Shortcut("ctrl+option+1"), to: target)
  model.press(try #require(model.configuration.hotkeys.first?.target))
  await model.navigator.settled()
  #expect(surface.shows == 0 && !surface.shown && model.navigator.command == nil)
  #expect(try observedFrame() == destination)
  #expect(try moveRecords(in: dataFolder) == [Record(pid: 42, before: original, after: destination)])
  model.press(try #require(HotkeyTarget("wicket://window?item=restore")))
  await model.navigator.settled()
  #expect(surface.shows == 0 && !surface.shown && model.navigator.command == nil)
  #expect(try observedFrame() == original)

  for (id, x) in [("left", -1000), ("right", -500)] {
    let side = try #require(HotkeyTarget("wicket://window?item=" + id))
    let shortcut = try Shortcut("option+cmd+" + id)
    model.store.bind(shortcut, to: side)
    let binding = try #require(model.configuration.hotkeys.first { $0.target == side })
    #expect(binding.keys == shortcut)
    model.press(binding.target)
    await model.navigator.settled()
    #expect(surface.shows == 0 && !surface.shown && model.navigator.command == nil)
    #expect(try observedFrame() == CGRect(x: x, y: -180, width: 500, height: 800))
  }
  model.press(try #require(HotkeyTarget("wicket://window?item=right")))
  await model.navigator.settled()
  #expect(surface.shows == 0 && !surface.shown && model.navigator.command == nil)
  #expect(try observedFrame() == CGRect(x: -667, y: -180, width: 667, height: 800))
  model.press(try #require(HotkeyTarget("wicket://window?item=restore")))
  await model.navigator.settled()
  #expect(try observedFrame() == CGRect(x: -1000, y: -180, width: 500, height: 800))

  let retired = try #require(HotkeyTarget("wicket://window?item=top"))
  model.store.bind(try Shortcut("option+cmd+up"), to: retired)
  let directory = CommandDirectory(extensions: model.extensions, hosts: [], store: model.store)
  #expect(directory.hotkeyResolutions().filter { $0.value != .ok } == [retired: .missingItem])
  model.press(retired)
  await model.navigator.settled()
  #expect(try observedFrame() == CGRect(x: -1000, y: -180, width: 500, height: 800))
  await model.finish()
}
