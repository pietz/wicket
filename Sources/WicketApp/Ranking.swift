import Foundation

struct SearchQuery: Sendable {
  struct Quality: Sendable {
    let tier: Int
    let score: Int
  }

  let input: String
  let scalars: [UInt32]
  private let words: [[UInt32]]

  init(_ input: String) {
    self.input = input
    scalars = Fold.query(input)
    words = Fold.words(input)
  }

  func score(_ key: SearchKey) -> Int? { FuzzyMatcher.score(scalars, words: words, key) }

  func quality(_ keys: [SearchKey], forFile: Bool = false) -> Quality? {
    if scalars.isEmpty { return Quality(tier: 0, score: 0) }
    guard let best = keys.lazy.compactMap(score).max() else { return nil }
    let tier = keys.lazy.map { Ranking.tier(scalars, $0, forFile: forFile) }.max() ?? 0
    return Quality(tier: tier, score: best)
  }
}

/// Names prepared once when apps are scanned or extensions discovered.
struct SearchIndex: Sendable {
  struct Match: Sendable {
    let row: Row
    /// Exact keyword arguments bypass fuzzy matching.
    let quality: SearchQuery.Quality?
  }

  private let entries: [(row: Row, keys: [SearchKey])]
  init(_ rows: [Row]) {
    entries = rows.map { ($0, ([$0.title] + ($0.keywords ?? [])).map(SearchKey.init)) }
  }
  /// The rows whose title or an alias fuzzy-matches the input, or all of them for empty input.
  func matches(_ input: String) -> [Row] {
    let query = SearchQuery(input)
    guard !query.scalars.isEmpty else { return entries.map(\.row) }
    return entries.filter { $0.keys.contains { query.score($0) != nil } }.map(\.row)
  }

  func scored(_ query: SearchQuery, forFile: Bool = false) -> [Match] {
    entries.compactMap { entry in
      query.quality(entry.keys, forFile: forFile).map { Match(row: entry.row, quality: $0) }
    }
  }

  /// Keep every exact keyword-with-argument match and at most `limit` fuzzy matches.
  func best(_ query: SearchQuery, limit: Int, including exact: ((Row) -> Bool)? = nil) -> [Match] {
    guard !query.scalars.isEmpty else { return [] }
    var exactRows: [Match] = []
    var scored: [(row: Row, quality: SearchQuery.Quality)] = []
    for entry in entries {
      if exact?(entry.row) == true {
        exactRows.append(Match(row: entry.row, quality: nil))
      } else if let quality = query.quality(entry.keys) {
        scored.append((entry.row, quality))
      }
    }
    // Tier first, as the root ranks, so reordered-word matches never crowd out a stronger one; the
    // manifest's order breaks ties.
    return exactRows
      + scored.enumerated().sorted { a, b in
        let (aq, bq) = (a.element.quality, b.element.quality)
        if aq.tier != bq.tier { return aq.tier > bq.tier }
        return aq.score == bq.score ? a.offset < b.offset : aq.score > bq.score
      }.prefix(limit).map { Match(row: $0.element.row, quality: $0.element.quality) }
  }
}

extension UsageStore {
  // Encoding a pair avoids delimiter collisions between arbitrary provider ids and input.
  private static func key(_ id: String, _ query: String) -> String {
    let normalized = Fold.query(query).compactMap(Unicode.Scalar.init).map(String.init).joined()
    return String(data: try! JSONEncoder().encode([id, normalized]), encoding: .utf8)!
  }
  func frecency(_ id: String, query: String, now: Date) -> Double {
    frecency(Self.key(id, query), now: now)
  }
  mutating func record(_ id: String, query: String, now: Date) {
    record(Self.key(id, query), now: now)
  }
  /// Each id's use under every input together. The empty input ranks by this total because picks
  /// are usually made after typing.
  func totals(now: Date) -> [String: Double] {
    let decoder = JSONDecoder()
    var totals: [String: Double] = [:]
    for (key, entry) in entries {
      guard let pair = try? decoder.decode([String].self, from: Data(key.utf8)), pair.count == 2 else {
        continue
      }
      totals[pair[0], default: 0] += Self.decay(entry, now: now)
    }
    return totals
  }
}
