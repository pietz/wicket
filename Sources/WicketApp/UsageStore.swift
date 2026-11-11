import Foundation

/// Frecency per item id: each use adds 1, and the total halves every `halfLife`.
/// Stores the decayed score and when it was computed, so nothing is rewritten as time passes.
struct UsageStore: Sendable {
  struct Entry: Codable, Sendable, Equatable {
    var score: Double
    var at: Date
  }

  static let halfLife: TimeInterval = 7 * 24 * 3600
  private(set) var entries: [String: Entry]

  init(entries: [String: Entry] = [:]) {
    self.entries = entries
  }

  func frecency(_ id: String, now: Date) -> Double {
    guard let entry = entries[id] else { return 0 }
    return Self.decay(entry, now: now)
  }

  mutating func record(_ id: String, now: Date) {
    entries[id] = Entry(score: frecency(id, now: now) + 1, at: now)
  }

  /// Drops entries that have decayed to noise.
  mutating func prune(now: Date) {
    entries = entries.filter { Self.decay($0.value, now: now) >= 0.01 }
  }

  static func decay(_ entry: Entry, now: Date) -> Double {
    let elapsed = max(0, now.timeIntervalSince(entry.at))
    return entry.score * pow(0.5, elapsed / halfLife)
  }

  // MARK: Persistence

  static func load(from url: URL) -> UsageStore {
    guard let data = try? Data(contentsOf: url),
      let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
    else { return UsageStore() }
    var store = UsageStore(entries: entries)
    store.prune(now: Date())
    return store
  }

  func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(entries).write(to: url, options: .atomic)
  }
}
