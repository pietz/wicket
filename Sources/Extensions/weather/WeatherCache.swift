import Darwin
import Foundation

struct WeatherCache<Value: Codable> {
  private struct Entry: Codable {
    let key: String
    let stored: Date
    let value: Value
  }

  let file: URL?

  func value(for key: String, fetch: () async throws -> Value) async throws -> Value {
    if let entry = entries().last(where: { $0.key == key }) { return entry.value }
    let value = try await fetch()
    store(value, for: key)
    return value
  }

  private func entries() -> [Entry] {
    guard let file, let data = try? Data(contentsOf: file),
      let saved = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    let cutoff = Date.now.addingTimeInterval(-600)
    return saved.filter { $0.stored > cutoff }
  }

  private func store(_ value: Value, for key: String) {
    guard let file else { return }
    // Wicket uses a new process for each request. Keep concurrent writes from losing entries.
    let lock = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lock >= 0 else { return }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { return }
    defer { flock(lock, LOCK_UN) }

    var saved = entries().filter { $0.key != key }
    saved.append(Entry(key: key, stored: .now, value: value))
    guard let data = try? JSONEncoder().encode(Array(saved.suffix(50))) else { return }
    try? data.write(to: file, options: .atomic)
  }
}
