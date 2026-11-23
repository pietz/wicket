import CoreGraphics
import Foundation
import Testing

@testable import WicketApp
@testable import window

// The bundled window extension. Its geometry and restore records are pure functions tested here; the
// program itself runs only for requests that list, since a submitted move would move a real window.

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

// MARK: - The program and its documentation

private func windowView(_ action: String? = nil, submitted: Bool = false) async throws
  -> ProviderView
{
  try await runBundled(
    "window", request: ProviderRequest(input: "", action: action, submitted: submitted))
}

@Test func theItemsAreTheMovesAndTheProgramListsThemWithoutMoving() async throws {
  let manifest = try bundled("window").manifest
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
