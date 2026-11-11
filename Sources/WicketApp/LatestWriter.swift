import Foundation

/// Serial writes, newest pending value only. Submission never blocks the keystroke path.
final class LatestWriter<Value: Sendable>: Sendable {
  private let task: Task<Void, Never>
  private let continuation: AsyncStream<Value>.Continuation

  init(write: @escaping @Sendable (Value) async -> Void) {
    let (values, continuation) = AsyncStream.makeStream(
      of: Value.self, bufferingPolicy: .bufferingNewest(1))
    self.continuation = continuation
    task = Task.detached(priority: .utility) {
      for await value in values { await write(value) }
    }
  }

  func submit(_ value: Value) { continuation.yield(value) }

  func finish() async {
    continuation.finish()
    await task.value
  }

  deinit {
    // What is waiting is still written; then the task ends.
    continuation.finish()
  }
}

/// Shared by providers that rank searchable rows and the host that records successful actions.
@MainActor
final class UsageHistory {
  private(set) var store: UsageStore
  private let writer: LatestWriter<UsageStore>
  init(url: URL) {
    store = UsageStore.load(from: url)
    writer = LatestWriter { store in
      do { try store.save(to: url) } catch {
        NSLog("Wicket: could not save usage: %@", error.localizedDescription)
      }
    }
  }
  func record(_ id: String, input: String) {
    store.record(id, query: input, now: Date())
    store.prune(now: Date())
    writer.submit(store)
  }
  func finish() async { await writer.finish() }
}
