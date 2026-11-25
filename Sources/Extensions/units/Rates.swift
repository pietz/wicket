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
  let value: Double
  let fetchedAt: Date
}

func exchangeRate(
  from source: String, to target: String, in directory: URL?, now: Date = .now,
  fetch: (String, String) async -> Data? = fetchRate
) async -> ExchangeRate? {
  if source == target { return ExchangeRate(value: 1) }
  let file = directory?.appending(path: "rate-\(source)-\(target).json")
  let decoder = JSONDecoder()
  let cached = file.flatMap { try? Data(contentsOf: $0) }.flatMap { data -> CachedRate? in
    guard let saved = try? decoder.decode(CachedRate.self, from: data), saved.value > 0, saved.value.isFinite
    else { return nil }
    return saved
  }
  if let cached, now.timeIntervalSince(cached.fetchedAt) < 6 * 3600 {
    return ExchangeRate(value: cached.value)
  }
  let stale = cached.map { ExchangeRate(value: $0.value, stale: true) }
  // Save a failed attempt separately so it cannot replace a rate another process just fetched.
  let retry = file?.appendingPathExtension("retry")
  if let retry, let data = try? Data(contentsOf: retry),
    let checked = try? decoder.decode(Date.self, from: data),
    now.timeIntervalSince(checked) < 60
  {
    return stale
  }
  guard let data = await fetch(source, target), let latest = try? decoder.decode(Rate.self, from: data),
    latest.base == source, latest.quote == target, latest.rate.isFinite, latest.rate > 0
  else {
    if let retry { try? JSONEncoder().encode(now).write(to: retry, options: .atomic) }
    return stale
  }
  if let file {
    let rate = CachedRate(value: latest.rate, fetchedAt: now)
    try? JSONEncoder().encode(rate).write(to: file, options: .atomic)
  }
  return ExchangeRate(value: latest.rate)
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
