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
  (.top, CGRect(x: 0, y: 33, width: 1512, height: 429)),
  (.bottom, CGRect(x: 0, y: 462, width: 1512, height: 430)),
  (.maximize, CGRect(x: 0, y: 33, width: 1512, height: 859)),
  (.almostMaximize, CGRect(x: 75, y: 76, width: 1361, height: 773)),
  (.center, CGRect(x: 456, y: 162, width: 600, height: 600)),
])
func everyMoveFillsItsShareOfTheVisibleFrame(move: Move, expected: CGRect) {
  let current = CGRect(x: 10, y: 50, width: 600, height: 600)
  #expect(target(move, window: current, displays: [laptop, external]) == expected)
}

@Test func halvesCoverAnOddScreenWithoutAGapAndCenterKeepsTheWindowOnIt() throws {
  let odd = Display(
    frame: CGRect(x: 0, y: 0, width: 1511, height: 981),
    visible: CGRect(x: 0, y: 25, width: 1511, height: 901))
  let current = CGRect(x: 0, y: 0, width: 2000, height: 300)
  let left = try #require(target(.left, window: current, displays: [odd]))
  let right = try #require(target(.right, window: current, displays: [odd]))
  #expect(left.maxX == right.minX && right.maxX == 1511)
  let top = try #require(target(.top, window: current, displays: [odd]))
  let bottom = try #require(target(.bottom, window: current, displays: [odd]))
  #expect(top.maxY == bottom.minY && bottom.maxY == 926)
  // A window wider than the screen is centered at the screen's width.
  #expect(target(.center, window: current, displays: [odd]) == CGRect(x: 0, y: 325, width: 1511, height: 300))
}

@Test func moveSucceedsOnTheWindowsOwnDisplay() {
  let onExternal = CGRect(x: 2000, y: 0, width: 800, height: 600)
  #expect(
    target(.left, window: onExternal, displays: [laptop, external])
      == CGRect(x: 1512, y: -273, width: 960, height: 1055))
  #expect(target(.maximize, window: onExternal, displays: [laptop, external]) == external.visible)
}

@Test func nextDisplayKeepsThePlaceAndShareOfTheScreenAndWrapsAround() throws {
  let displays = [laptop, external]
  // A left half stays a left half.
  let leftHalf = try #require(target(.left, window: .zero, displays: [laptop]))
  #expect(
    target(.nextDisplay, window: leftHalf, displays: displays)
      == CGRect(x: 1512, y: -273, width: 960, height: 1055))
  // From the rightmost display back to the first.
  let maximized = external.visible
  #expect(target(.nextDisplay, window: maximized, displays: displays) == laptop.visible)
  // A small window keeps its relative place, scaled, and never crosses the edges.
  let small = CGRect(x: 1512 + 1700, y: -273, width: 400, height: 300)
  let moved = try #require(target(.nextDisplay, window: small, displays: displays))
  #expect(moved.width == 315 && moved.height == 244 && laptop.visible.contains(moved))
  #expect(target(.nextDisplay, window: leftHalf, displays: [laptop]) == nil)
  // Three displays in the order they stand, left to right, whatever order AppKit lists them in.
  let left = Display(
    frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
    visible: CGRect(x: -1440, y: 25, width: 1440, height: 875))
  let order = [external, laptop, left]
  #expect(target(.nextDisplay, window: left.visible, displays: order) == laptop.visible)
  #expect(target(.nextDisplay, window: laptop.visible, displays: order) == external.visible)
  #expect(target(.nextDisplay, window: external.visible, displays: order) == left.visible)
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
    if !enhanced, applySize, sizeError == .success { current.size = adjustedSize ?? size }
    return sizeError
  }

  func move(_ move: Move, in folder: URL, commandName: String = "Window Manager") throws -> Row? {
    events.removeAll()
    let failure = perform(
      .stock(move), layout: Layout(), pid: 42, name: "Test App", commandName: commandName, displays: [laptop],
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
  #expect(ax.events == [.readFrame, .size, .position, .size, .readFrame])
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
  let repeated = try ax.move(.left, in: folder)
  #expect(repeated == nil, "\(repeated?.title ?? "")")
  #expect(
    try moveRecords(in: folder) == [
      Record(pid: 42, before: FakeWindowAccessibility.original, after: adjusted)
    ])

  ax.adjustedSize = nil
  let restored = try ax.move(.restore, in: folder)
  #expect(restored == nil, "\(restored?.title ?? "")")
  #expect(ax.current == FakeWindowAccessibility.original)
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
  #expect(try moveRecords(in: folder) == [Record(pid: 42, before: original, after: partial)])
}

@Test(arguments: [0, 1, 2])
func enhancedInterfaceStaysOffThroughReadbackAndIsRestoredAfterward(readbackFailures: Int) throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let ax = FakeWindowAccessibility()
  ax.enhanced = true
  ax.readbackErrors = Array(repeating: .cannotComplete, count: readbackFailures)
  let result = try ax.move(.left, in: folder)
  #expect(ax.current == target(.left, window: FakeWindowAccessibility.original, displays: [laptop]))
  #expect(ax.enhanced)
  let reads: [FakeWindowAccessibility.Event] =
    readbackFailures == 0 ? [.readFrame] : [.readFrame, .readFrame]
  #expect(ax.events == [.readFrame, .enhanced(false), .size, .position, .size] + reads + [.enhanced(true)])
  if readbackFailures == 2 {
    #expect(result?.title == "Couldn't verify Test App's final window position")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "moves.txt").path))
  } else {
    #expect(result == nil)
    #expect(
      try moveRecords(in: folder) == [
        Record(pid: 42, before: FakeWindowAccessibility.original, after: ax.current)
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
  #expect(ax.current == target(.left, window: FakeWindowAccessibility.original, displays: [laptop]))
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
      Record(pid: 42, before: FakeWindowAccessibility.original, after: ax.current)
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
    window.parse(records: history) == [Record(pid: 42, before: original, after: partial)], "\(history)")

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
  #expect(manifest.name == "Window Manager" && manifest.keyword == "window")
  #expect(!manifest.matches("window"))
  let rows = try #require(manifest.items)
  #expect(rows.map(\.id) == Move.allCases.map(\.rawValue))
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
  #expect(try await windowView("sideways", submitted: true).items == rows)
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
  #expect(row.subtitle?.contains("add it again") == true)
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

@Test func aGapInsetsEveryMoveAndSeparatesTheHalves() throws {
  let layout = Layout(gap: "8", almostMaximize: "80")
  let current = CGRect(x: 10, y: 50, width: 600, height: 600)
  func moved(_ move: Move) throws -> CGRect {
    try #require(target(move, window: current, displays: [laptop], layout: layout))
  }
  let screen = laptop.visible
  #expect(try moved(.maximize) == screen.insetBy(dx: 8, dy: 8))
  let (left, right) = (try moved(.left), try moved(.right))
  #expect(left.minX == 8 && right.minX - left.maxX == 8 && right.maxX == screen.maxX - 8)
  #expect(left.minY == screen.minY + 8 && left.height == screen.height - 16)
  let (top, bottom) = (try moved(.top), try moved(.bottom))
  #expect(bottom.minY - top.maxY == 8 && bottom.maxY == screen.maxY - 8)
  // Almost Maximize takes its percent of the visible frame, centered.
  let almost = try moved(.almostMaximize)
  #expect(almost.width == (1512 * 0.8).rounded() && almost.height == (859 * 0.8).rounded())
  #expect(abs(almost.midX - screen.midX) <= 1 && abs(almost.midY - screen.midY) <= 1)
}

@Test func settingsThatAreNoNumberOrOutOfRangeKeepTheDefaults() {
  #expect(Layout() == Layout(gap: "0", almostMaximize: "90"))
  #expect(Layout(gap: "wide", almostMaximize: "150") == Layout())
  #expect(Layout(gap: "-4", almostMaximize: "5") == Layout())
  #expect(Layout(gap: "12.4").gap == 12 && Layout(almostMaximize: "75").almost == 0.75)
}

// MARK: - Saved moves and Capture

@MainActor
@Test(
  arguments: [
    (nil, "Set fields.definition"),
    ("{", "Set fields.definition"),
    (#"{"placement":{}}"#, "Set kind to move"),
    (#"{"kind":42}"#, "Set kind to move"),
    (#"{"kind":"layout","placement":{}}"#, "Set kind to move"),
    (#"{"kind":"move"}"#, "Set placement to an object"),
    (#"{"kind":"move","placement":[]}"#, "Set placement to an object"),
    (
      #"{"kind":"move","placement":{"rect":[0,0,1,1]}}"#,
      "Set placement.display to current, main, next, or a display UUID"
    ),
    (#"{"kind":"move","placement":{"display":1,"rect":[0,0,1,1]}}"#, "Set placement.display"),
    (#"{"kind":"move","placement":{"display":"primary","rect":[0,0,1,1]}}"#, "Set placement.display"),
    (
      #"{"kind":"move","placement":{"display":"main","fallback":1,"rect":[0,0,1,1]}}"#,
      "Set placement.fallback"
    ),
    (
      #"{"kind":"move","placement":{"display":"main","fallback":"primary","rect":[0,0,1,1]}}"#,
      "Set placement.fallback"
    ),
    (#"{"kind":"move","placement":{"display":"main","rect":[0,0,1,1],"gap":-1}}"#, "Set placement.gap"),
    (#"{"kind":"move","placement":{"display":"main","rect":[0,0,1,1],"gap":"8"}}"#, "Set placement.gap"),
    (#"{"kind":"move","placement":{"display":"main"}}"#, "Set placement.rect"),
    (#"{"kind":"move","placement":{"display":"main","rect":[0,0,1]}}"#, "Set placement.rect"),
    (#"{"kind":"move","placement":{"display":"main","rect":[0.5,0,0.6,1]}}"#, "Set placement.rect"),
    (#"{"kind":"move","placement":{"display":"main","rect":[0,0,0,1]}}"#, "Set placement.rect"),
    (#"{"kind":"move","placement":{"display":"main","rect":[0,0,1e309,1]}}"#, "Set placement.rect"),
  ] as [(String?, String)])
func invalidWindowDefinitionsGiveAClearRowWithoutTouchingWindows(definition: String?, hint: String) throws {
  let request = window.JSON.object([
    "submitted": .bool(true), "action": .string("apply-definition"),
    "fields": .object(definition.map { ["definition": .string($0)] } ?? [:]),
  ])
  let view = windowAnswer(
    request, manifestBytes: [],
    move: { _, _, _ in
      Issue.record("An invalid definition reached the Accessibility adapter")
      return nil
    },
    capture: { _ in
      Issue.record("An invalid definition reached Capture")
      return ""
    })
  let output = try #require(view)
  let row = try #require(JSONDecoder().decode(ProviderView.self, from: Data(output.utf8)).items.first)
  #expect(row.title == "Invalid window move definition")
  #expect(row.subtitle?.contains(hint) == true)
}

@Test func customPlacementsResolveDisplaysAndQuantizeEdges() throws {
  let uuid = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
  var secondary = external
  secondary.uuid = uuid
  func placement(_ display: String, fallback: String? = nil, rect: String = "[0,0,1,1]") throws -> Placement {
    let fallbackField = fallback.map { #","fallback":"\#($0)""# } ?? ""
    return try Placement.decode(
      #"{"kind":"move","placement":{"display":"\#(display)"\#(fallbackField),"rect":\#(rect)}}"#
    ).get()
  }
  let displays = [laptop, secondary]
  let current = external.visible
  #expect(
    try placement("current").destination(for: current, displays: displays, defaultGap: 0).get() == current)
  for selector in ["main", "next"] {
    #expect(
      try placement(selector).destination(for: current, displays: displays, defaultGap: 0).get()
        == laptop.visible)
  }
  let explicit = try placement(uuid.uuidString.lowercased())
  #expect(try explicit.destination(for: laptop.visible, displays: displays, defaultGap: 0).get() == current)
  #expect(throws: Placement.Failure.self) {
    _ = try explicit.destination(for: laptop.visible, displays: [laptop], defaultGap: 0).get()
  }
  #expect(
    try placement(uuid.uuidString, fallback: "current")
      .destination(for: laptop.visible, displays: [laptop], defaultGap: 8).get()
      == laptop.visible.insetBy(dx: 8, dy: 8))
  let top = try placement("main", rect: "[0,0,1,0.5]").destination(
    for: current, displays: displays, defaultGap: 9
  )
  .get()
  let bottom = try placement("main", rect: "[0,0.5,1,0.5]")
    .destination(for: current, displays: displays, defaultGap: 9).get()
  #expect(top.maxY == bottom.minY)
  #expect(top.union(bottom) == laptop.visible.insetBy(dx: 9, dy: 9))
}

@Test func unavailableWindowDisplaysNameBothSelectorsInTheFailureRow() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let primary = "01234567-89AB-CDEF-0123-456789ABCDEF"
  let fallback = "FEDCBA98-7654-3210-FEDC-BA9876543210"
  let placement = try Placement.decode(
    #"{"kind":"move","placement":{"display":"\#(primary)","fallback":"\#(fallback)","rect":[0,0,1,1]}}"#
  ).get()
  let ax = FakeWindowAccessibility()
  let failure = try #require(
    perform(
      .custom(placement), layout: Layout(), pid: 42, name: "Test App", commandName: "Window Manager",
      displays: [laptop], recordsFile: folder.appending(path: "moves.txt"), ax: ax))
  let row = try JSONDecoder().decode(Row.self, from: Data(failure.utf8))
  #expect(row.title == "Can't apply window move")
  #expect(row.subtitle == "Display \(primary) and fallback \(fallback) are unavailable")
  #expect(ax.events == [.readFrame])
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
    + ["Window", "Placement", "Capture", "JSON"].map { source.appending(path: $0 + ".swift").path }
    + ["-o", folder.appending(path: "main").path]
  try compiler.run()
  compiler.waitUntilExit()
  try #require(compiler.terminationStatus == 0)
  return folder
}

@MainActor @Test func captureBecomesAHeadlessMoveAndAHiddenUserItemHotkey() async throws {
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
  let destination = CGRect(x: 520, y: 240, width: 240, height: 300)
  // Simulate the user moving the focused window after Capture, before using the saved item.
  try JSONEncoder().encode(original).write(to: frameFile)
  func observedFrame() throws -> CGRect {
    try JSONDecoder().decode(CGRect.self, from: Data(contentsOf: frameFile))
  }
  let focused = entries.first(where: \.focused)
  let saved = try #require(focused)
  let rectangle = saved.rect.map { String($0) }.joined(separator: ",")
  let definition =
    #"{"kind":"move","placement":{"display":"\#(saved.display)","rect":[\#(rectangle)],"gap":0}}"#
  let item = Row(
    id: "coding", title: "Coding",
    actions: [
      .run(
        Address(
          id: "extension:window", fields: ["definition": definition],
          action: "apply-definition", hidden: true))
    ])
  try JSONEncoder().encode(["items": [item]]).write(to: folder.appending(path: "user.json"))
  try saveProviders([.init("extension:window")], in: root)
  let (queryStatus, query) = try await cli(root, ["--query", "Coding"])
  #expect(queryStatus == 0 && query["items"].array.contains { $0["row"]["id"].string == "user-item:coding" })
  #expect(try observedFrame() == original)

  let command = try #require(
    ExtensionHost.discover(root.appending(path: "extensions"), bundled: nil)
      .0["extension:window"])
  let target = try #require(HotkeyTarget("wicket://window?user-item=coding"))
  guard case .run(let action)? = command.item(for: target)?.actions.first?.kind else {
    Issue.record("The saved item has no run action")
    return
  }
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
  let broken = try extensionFolder(root, name: "window", fields: ["contract": 1])
  try FileManager.default.moveItem(
    at: bundledWindow.appending(path: "user.json"), to: broken.appending(path: "user.json"))
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
  await model.finish()
}
