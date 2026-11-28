import AppKit
import Darwin
import SwiftUI
import Testing

@testable import WicketApp

// Opt-in timing of the native page renderer offscreen.
// WICKET_PAGE_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter pageRendererTiming

private let timingEnabled = ProcessInfo.processInfo.environment["WICKET_PAGE_TIMING"] == "1"

private func milliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func footprint(_ pid: pid_t) -> Double {
  var info = rusage_info_v4()
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
  }
  return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
}

/// A long reply with every kind of block, `count` sections of it.
private func longReply(_ count: Int) -> String {
  (0..<count).map { index in
    """
    ## Section \(index)
    Paragraph \(index) explains **what changed** and why, with `inline code`, a [link](https://example.com) and enough words to wrap onto a second line in the panel.

    - First point of \(index)
    - Second point, a little longer than the first

    <row title="Item \(index)" subtitle="Detail" copy="\(index)"/>
    <row title="Other \(index)" open="https://example.com/\(index)"/>

    | Name | Value |
    |------|------:|
    | a\(index) | \(index * 3) |

    """ + (index % 4 == 0 ? "```\nswift build \(index)\n```\n\n" : "")
      + (index % 5 == 0 ? "<chart labels=\"a,b,c,d\"><line name=\"x\" values=\"1,3,2,4\"/></chart>\n\n" : "")
  }.joined()
}

@MainActor @Test(.enabled(if: timingEnabled, "Set WICKET_PAGE_TIMING=1"))
func pageRendererTiming() {
  _ = NSApplication.shared
  let clock = ContinuousClock()
  let memoryBefore = footprint(getpid())
  var results: [(String, String)] = []
  func record(_ name: String, _ value: String) {
    results.append((name, value))
  }

  let renderer = NativePageRenderer()
  let window = PalettePanel()
  window.setContentSize(NSSize(width: 640, height: 500))
  let host = NSHostingView(rootView: NativePageView(renderer: renderer).frame(width: 640, height: 500))
  window.contentView = host
  defer { window.contentView = nil }
  func layOut() { host.layoutSubtreeIfNeeded() }

  // First page in a fresh process.
  let first = Page(body: longReply(3), runs: false)
  var start = clock.now
  renderer.update(first, turn: "first", streaming: false)
  layOut()
  record("First page, cold process (ms)", String(format: "%.1f", milliseconds(clock.now - start)))

  // A new page in the warm renderer.
  var warm: [Double] = []
  for index in 0..<10 {
    let page = Page(body: longReply(3) + "\n\nVariant \(index)", runs: false)
    start = clock.now
    renderer.update(page, turn: "warm-\(index)", streaming: false)
    layOut()
    warm.append(milliseconds(clock.now - start))
  }
  warm.sort()
  record("New page, warm (median ms)", String(format: "%.1f", warm[warm.count / 2]))

  // Streaming: a reply of 40 sections growing in 80 steps, each update of the page shown.
  let reply = longReply(40)
  let steps = 80
  var updates: [Double] = []
  for step in 1...steps {
    let end = reply.index(reply.startIndex, offsetBy: reply.count * step / steps)
    let page = Page(body: String(reply[..<end]), runs: false, streaming: step < steps)
    start = clock.now
    renderer.update(page, turn: "stream", streaming: step < steps)
    layOut()
    updates.append(milliseconds(clock.now - start))
  }
  let sortedUpdates = updates.sorted()
  record(
    "Streaming update, 80 steps to \(reply.count) characters (median / p90 / max ms)",
    String(
      format: "%.1f / %.1f / %.1f", sortedUpdates[steps / 2], sortedUpdates[steps * 9 / 10],
      sortedUpdates.last!))
  record(
    "Streaming update, last 10 steps (median ms)",
    String(format: "%.1f", updates.suffix(10).sorted()[5]))

  // Selection: arrowing through the targets of the finished page.
  var selections: [Double] = []
  for index in 0..<20 {
    let id = "#\(index)"
    start = clock.now
    renderer.selected = id
    layOut()
    selections.append(milliseconds(clock.now - start))
  }
  selections.sort()
  record("Selection change (median ms)", String(format: "%.1f", selections[10]))
  renderer.selected = nil

  // A large page: 150 sections, about 1,200 blocks.
  let large = Page(body: longReply(150), runs: false)
  start = clock.now
  renderer.update(large, turn: "large", streaming: false)
  layOut()
  record(
    "Large page, \(large.source.count) characters (ms)",
    String(format: "%.1f", milliseconds(clock.now - start)))

  record("Memory growth (MB)", String(format: "%.0f", footprint(getpid()) - memoryBefore))

  for (name, value) in results { print("PAGE TIMING | \(name) | \(value)") }
}
