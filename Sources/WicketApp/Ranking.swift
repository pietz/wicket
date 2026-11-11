import Foundation

/// Prepared once when apps are scanned or extensions discovered, never rebuilt per keystroke. It only
/// filters; `Ranking.compose` or `Ranking.order` orders what it returns.
struct SearchIndex: Sendable {
  private let entries: [(row: Row, keys: [SearchKey])]
  init(_ rows: [Row]) {
    entries = rows.map { ($0, ([$0.title] + ($0.keywords ?? [])).map(SearchKey.init)) }
  }
  /// The rows whose title or an alias fuzzy-matches the input, or all of them for empty input.
  func matches(_ input: String) -> [Row] {
    let query = Fold.query(input)
    guard !query.isEmpty else { return entries.map(\.row) }
    return entries.filter { $0.keys.contains { FuzzyMatcher.score(query, $0) != nil } }.map(\.row)
  }
  /// At most `limit` matching rows, the best fuzzy scores first; none for empty input, which has no best.
  func best(_ input: String, limit: Int) -> [Row] {
    let query = Fold.query(input)
    guard !query.isEmpty else { return [] }
    var scored: [(row: Row, score: Int)] = []
    for entry in entries {
      if let score = entry.keys.compactMap({ FuzzyMatcher.score(query, $0) }).max() {
        scored.append((entry.row, score))
      }
    }
    // A stable sort keeps the manifest's order among equal scores.
    return scored.enumerated().sorted { a, b in
      a.element.score == b.element.score ? a.offset < b.offset : a.element.score > b.element.score
    }.prefix(limit).map(\.element.row)
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
}
