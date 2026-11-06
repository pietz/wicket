import Foundation
import os

/// Performance logging. Read with:
/// `log stream --predicate 'subsystem == "app.wicket" && category == "perf"'`
enum Perf {
    static let logger = Logger(subsystem: "app.wicket", category: "perf")
    static let signposter = OSSignposter(subsystem: "app.wicket", category: "perf")

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func ms(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%.2f ms", ms)
    }
}
