import Foundation

/// Merges results from every source into one order.
public enum Ranker {
    /// Frecency adds at most this much, so habit breaks ties but never beats a clearly better match.
    static let maxUsageBoost = 18.0

    /// Best first: by relevance tier, then score plus frecency boost, then (for a non-empty query)
    /// the shorter title, then by name. An empty query therefore lists by usage, then name.
    public static func rank(
        _ items: [Item], query: String, usage: (String) -> Double, limit: Int = .max
    ) -> [Item] {
        let typed = !Fold.query(query).isEmpty
        var scored = items.map { (item: $0, score: $0.score + usageBoost(usage($0.id))) }
        scored.sort { a, b in
            if a.item.relevance != b.item.relevance { return a.item.relevance < b.item.relevance }
            if a.score != b.score { return a.score > b.score }
            let ta = a.item.title
            let tb = b.item.title
            if typed, ta.count != tb.count { return ta.count < tb.count }
            switch ta.localizedStandardCompare(tb) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.item.id < b.item.id
            }
        }
        return scored.prefix(limit).map(\.item)
    }

    static func usageBoost(_ frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return min(maxUsageBoost, 6 * log2(1 + frecency))
    }
}
