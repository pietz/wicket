import Foundation
import os

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

/// A newest-first JSON list in the private folder (`Edition.privateDirectory`), kept from the agent: the
/// clipboard and agent histories. Read once; written atomically off the main path by a latest-value
/// writer into a folder created 0700, so the file is unreachable for others whatever its mode.
enum PrivateList {
  /// A missing or unreadable file is an empty list.
  static func read<Item: Decodable>(_ url: URL) -> [Item] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Item].self, from: $0) } ?? []
  }
  /// A failed save logs only its error code.
  static func writer<Item: Encodable & Sendable>(_ url: URL, log: Logger) -> LatestWriter<[Item]> {
    LatestWriter { items in
      do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try encoder.encode(items).write(to: url, options: .atomic)
      } catch {
        log.error("save failed, code \((error as NSError).code, privacy: .public)")
      }
    }
  }
  /// The newest `count` items no older than `days`, or nil when nothing expired. Costs one date
  /// comparison then, since the oldest item is last.
  static func retained<Item>(
    _ items: [Item], count: Int, days: Int, date: (Item) -> Date, now: Date
  ) -> [Item]? {
    let oldest = now.addingTimeInterval(-Double(days) * 24 * 3600)
    guard items.count > count || (items.last.map { date($0) < oldest } ?? false) else { return nil }
    let kept = items.prefix(count).filter { date($0) >= oldest }
    return kept.count == items.count ? nil : Array(kept)
  }
}
