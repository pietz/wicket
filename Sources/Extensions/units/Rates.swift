import Foundation

private struct Rate: Decodable {
  let base: String
  let quote: String
  let rate: Double
}

struct ExchangeRate: Equatable, Sendable {
  let value: Double
  var stale = false
}

private struct CachedRate: Codable {
  let value: Double?
  let fetchedAt: Date
  let checkedAt: Date
}

func exchangeRate(
  from source: String, to target: String, in directory: URL?, now: Date = .now,
  fetch: (String, String) async -> Data? = fetchRate
) async -> ExchangeRate? {
  if source == target { return ExchangeRate(value: 1) }
  let file = directory?.appending(path: "rate-\(source)-\(target).json")
  let decoder = JSONDecoder()
  let cached = file.flatMap { try? Data(contentsOf: $0) }.flatMap {
    try? decoder.decode(CachedRate.self, from: $0)
  }
  let oldRate = cached?.value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
  if let cached {
    if let oldRate, now.timeIntervalSince(cached.fetchedAt) < 6 * 3600 {
      return ExchangeRate(value: oldRate)
    }
    // An offline refresh should not stall every subsequent keystroke.
    if now.timeIntervalSince(cached.checkedAt) < 60 {
      return oldRate.map { ExchangeRate(value: $0, stale: true) }
    }
  }

  let latest = await fetch(source, target).flatMap { try? decoder.decode(Rate.self, from: $0) }
  let fresh = latest.flatMap { rate in
    rate.base == source && rate.quote == target && rate.rate.isFinite && rate.rate > 0 ? rate.rate : nil
  }
  let value = fresh ?? oldRate
  if let file {
    let fetchedAt = fresh == nil ? cached?.fetchedAt ?? now : now
    let entry = CachedRate(value: value, fetchedAt: fetchedAt, checkedAt: now)
    // Each pair has its own file so concurrent lookups cannot lose another pair's rate.
    try? JSONEncoder().encode(entry).write(to: file, options: .atomic)
  }
  return value.map { ExchangeRate(value: $0, stale: fresh == nil) }
}

private func fetchRate(_ source: String, _ target: String) async -> Data? {
  let session = URLSession(configuration: .ephemeral)
  defer { session.finishTasksAndInvalidate() }
  guard let url = URL(string: "https://api.frankfurter.dev/v2/rate/\(source)/\(target)"),
    let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 4)),
    (response as? HTTPURLResponse)?.statusCode == 200
  else { return nil }
  return data
}
