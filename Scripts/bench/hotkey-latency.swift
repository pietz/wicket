// Measures hotkey-to-visible latency for any launcher, from outside the process.
//
// Posts ⌥Space through the HID event tap, then polls the window server until a window of the target
// process at least 300×40 pt (Tinycast opens as a compact bar) is on screen. Closes it with Escape and repeats. "Visible" means the
// window server lists the window on screen, which is the same for every app measured; it does not
// include the final compositor frame (~one display refresh).
//
//   swiftc -O Scripts/bench/hotkey-latency.swift -o build/hotkey-latency
//   build/hotkey-latency <process name> [runs]
// It takes over the keyboard and screen while it runs: only run it when nobody is using the Mac.
// Needs the Accessibility permission for the terminal that runs it (to post events).
import AppKit
import CoreGraphics

var args = CommandLine.arguments
// --ctrl adds Control (⌃⌥Space), for when another app owns ⌥Space.
let hotkeyFlags: CGEventFlags = args.contains("--ctrl") ? [.maskAlternate, .maskControl] : .maskAlternate
args.removeAll { $0 == "--ctrl" }
guard args.count >= 2 else { print("usage: hotkey-latency <process name> [runs] [--ctrl]"); exit(2) }
let name = args[1]
let runs = args.count > 2 ? Int(args[2]) ?? 30 : 30

guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
    print("\(name) is not running"); exit(1)
}
let pid = target.processIdentifier

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

func panelOnScreen() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return false }
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
            let b = info[kCGWindowBounds as String] as? [String: CGFloat],
            (b["Width"] ?? 0) >= 300, (b["Height"] ?? 0) >= 40,
            (info[kCGWindowAlpha as String] as? Double ?? 0) > 0
        else { return false }
        return true
    }
}

func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

func waitUntil(_ visible: Bool, timeoutMs: Double = 2000) -> Bool {
    let start = now()
    while now() - start < timeoutMs {
        if panelOnScreen() == visible { return true }
    }
    return false
}

// Poll cost bounds the resolution.
var t = now(); for _ in 0..<20 { _ = panelOnScreen() }; let pollMs = (now() - t) / 20

if panelOnScreen() { press(53); _ = waitUntil(false) }
usleep(500_000)

var samples: [Double] = []
for i in 0..<runs {
    let t0 = now()
    press(49, flags: hotkeyFlags)  // ⌥Space
    // Abort at once: without a panel, every further keystroke lands in the frontmost app.
    guard waitUntil(true) else { print("run \(i): panel never appeared; aborting"); exit(1) }
    samples.append(now() - t0)
    usleep(150_000)
    press(53)  // Escape
    if !waitUntil(false) { press(49, flags: hotkeyFlags); _ = waitUntil(false) }
    usleep(UInt32.random(in: 350_000...650_000))
}
guard !samples.isEmpty else { exit(1) }
samples.sort()
func pct(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
print(String(format: "%@: n=%d  median %.1f ms  p90 %.1f ms  min %.1f  max %.1f  (poll %.2f ms)",
    name, samples.count, pct(0.5), pct(0.9), samples.first!, samples.last!, pollMs))
