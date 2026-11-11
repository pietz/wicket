import Foundation

/// Prepared once when apps are scanned, never rebuilt per keystroke.
struct SearchIndex: Sendable {
  private let entries: [(row: Row, keys: [SearchKey])]
  init(_ rows: [(Row, [String])]) {
    entries = rows.map { ($0.0, ([$0.0.title] + ($0.0.keywords ?? []) + $0.1).map(SearchKey.init)) }
  }
  func search(_ input: String, usage: UsageStore, now: Date = Date(), namespace: String = "")
    -> [Row]
  {
    let query = Fold.query(input)
    let matches = entries.compactMap { entry -> (Row, Int, Int, Double)? in
      if query.isEmpty {
        return (entry.row, 0, 0, usage.frecency(namespace + entry.row.id, query: input, now: now))
      }
      var best: (tier: Int, score: Int)?
      for key in entry.keys {
        guard let score = FuzzyMatcher.score(query, key) else { continue }
        let tier = Ranking.tier(query, folded: key.compact)
        if best == nil || tier > best!.tier || (tier == best!.tier && score > best!.score) {
          best = (tier, score)
        }
      }
      guard let best else { return nil }
      return (
        entry.row, best.tier, best.score,
        usage.frecency(namespace + entry.row.id, query: input, now: now)
      )
    }
    return matches.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      if $0.3 != $1.3 { return $0.3 > $1.3 }
      if $0.2 != $1.2 { return $0.2 > $1.2 }
      let order = $0.0.title.localizedStandardCompare($1.0.title)
      return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
    }.map(\.0)
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
