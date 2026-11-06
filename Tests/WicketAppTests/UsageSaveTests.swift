import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketApp

// Usage is saved off the keystroke path; saves that overlapped could finish out of order and leave
// an older snapshot on disk.

private final class WriteLog: Sendable {
    let state = Mutex((written: [Int](), active: 0, mostActive: 0))
}

private func within(_ seconds: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@Test func writesAreSerialAndTheNewestWins() async {
    let log = WriteLog()
    let (gate, open) = AsyncStream.makeStream(of: Void.self)
    let writer = LatestWriter<Int> { value in
        log.state.withLock {
            $0.active += 1
            $0.mostActive = max($0.mostActive, $0.active)
        }
        // The first write is slow: everything submitted meanwhile waits for it.
        if value == 1 { for await _ in gate { break } }
        log.state.withLock {
            $0.written.append(value)
            $0.active -= 1
        }
    }
    writer.submit(1)
    #expect(await within { log.state.withLock { $0.active == 1 } })
    for value in 2...50 { writer.submit(value) }
    open.yield()
    #expect(await within { log.state.withLock { $0.written.last == 50 } })
    let state = log.state.withLock { $0 }
    #expect(state.written == [1, 50])
    #expect(state.mostActive == 1)
}

@MainActor @Test func theNewestUsageIsWhatIsSaved() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/\(UUID().uuidString)/usage.json")
    let model = PaletteModel(sources: [], usageURL: url)
    let items = (1...200).map { item("app \($0)") }
    for item in items { model.recordUse(of: item) }
    #expect(await within { UsageStore.load(from: url).entries.count == items.count })
    // Nothing older lands afterwards.
    try await Task.sleep(for: .milliseconds(100))
    #expect(UsageStore.load(from: url).entries.count == items.count)
}
