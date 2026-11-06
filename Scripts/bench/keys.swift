// Posts keystrokes for smoke tests: keys "opt-space" "ctrl-opt-space" "down" "up" "esc" "return",
// or any lowercase letters, e.g. `keys ctrl-opt-space await:Wicket t e r m down`. 120 ms between keys.
// `await:<process>` waits up to 2 s for that process's palette (a window of at least 300×40 pt) and
// exits 1 without typing anything further if it never appears.
// Like the latency harness, it takes over the keyboard: only run it on an idle Mac.
import AppKit
import CoreGraphics

func paletteVisible(_ name: String) -> Bool {
    guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?
        .processIdentifier,
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
            let b = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return false }
        return (b["Width"] ?? 0) >= 300 && (b["Height"] ?? 0) >= 40
    }
}

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
    "k": 40, "n": 45, "m": 46, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "space": 49, "delete": 51, "return": 36, "esc": 53, "down": 125, "up": 126,
]
let source = CGEventSource(stateID: .hidSystemState)
for arg in CommandLine.arguments.dropFirst() {
    if arg.hasPrefix("await:") {
        let name = String(arg.dropFirst(6))
        let deadline = Date().addingTimeInterval(2)
        while !paletteVisible(name) {
            if Date() > deadline { print("\(name) palette not visible; stopping"); exit(1) }
            usleep(10_000)
        }
        continue
    }
    var parts = arg.split(separator: "-").map(String.init)
    let key = parts.removeLast()
    var flags: CGEventFlags = []
    for m in parts {
        switch m {
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        case "cmd": flags.insert(.maskCommand)
        default: break
        }
    }
    guard let code = codes[key] else { print("unknown key \(key)"); exit(2) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
    usleep(120_000)
}
