import Darwin
import Foundation
import Testing

@testable import WicketApp

@Test func concurrentSlowExtensionsKeepTheirDeadlinesAndCancellation() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let count = max(16, ProcessInfo.processInfo.activeProcessorCount + 4)
  let watchdog = DispatchSource.makeTimerSource(queue: .global())
  watchdog.schedule(deadline: .now() + 3.5, repeating: .milliseconds(50))
  watchdog.setEventHandler {
    for i in 0..<count {
      if let text = try? String(contentsOf: root.appending(path: "pid-\(i)"), encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGKILL)
      }
    }
  }
  watchdog.resume()
  defer { watchdog.cancel() }
  let runs = try (0..<count).map { i in
    try command(
      extensionFolder(root, name: "run-\(i)", script: "echo $$ > '\(root.path)/pid-\(i)'\nexec /bin/sleep 30")
    )
  }
  let start = ContinuousClock.now
  let tasks = runs.enumerated().map { i, run in
    Task {
      var runner = ExtensionRunner()
      runner.deadline = i.isMultiple(of: 2) ? .milliseconds(120) : .seconds(30)
      do {
        _ = try await runner.run(run, request: .init(input: ""))
        Issue.record("Expected cancellation or deadline")
      } catch {}
    }
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(80)) {
    for (i, task) in tasks.enumerated() where !i.isMultiple(of: 2) { task.cancel() }
  }
  for task in tasks { await task.value }
  #expect(ContinuousClock.now - start < .seconds(3))
}
