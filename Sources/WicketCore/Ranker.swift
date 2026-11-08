import Foundation

/// Merges results from every root source into one order.
///
/// Relevance tiers come first (exact, answer, match, fallback). Within a tier two policies apply:
/// - **Fixed menu**: the host's fallback rows (`FallbackSource`: Run Agent) keep the order their
///   source gave, never moved by habit or by title.
/// - **Host-scored**: the host's other items (apps, files, calculator, built-ins) by score plus a
///   frecency boost, then (for a non-empty query) the shorter title, then name. An empty query
///   therefore lists by usage, then name.
///
/// One exception to the tiers: when the query reads like a request (`RequestText`) and nothing is a
/// strong match, the lead fallback (Run Agent) moves to the top, so Return asks it. Ranking runs again
/// on every late result, so a strong match arriving later takes the top back.
public enum Ranker {
    /// Frecency adds at most this much, so habit breaks ties but never beats a clearly better match.
    static let maxUsageBoost = 18.0

    /// A host-scored match is strong at this many points per query scalar: about what a match earns
    /// when the query runs through the title word by word (7 per scalar in a run, a jump to a word
    /// start the same), well above the matcher's floor of 2 for scattered letters.
    static let strongScorePerScalar = 5.0

    public static func rank(_ items: [Item], query: String, usage: (String) -> Double) -> [Item] {
        let typed = !Fold.query(query).isEmpty
        struct Candidate {
            let item: Item
            /// Position in the input, which is a fallback source's order.
            let position: Int
            let score: Double
        }
        var candidates = items.enumerated().map { position, item in
            let boost = item.relevance == .fallback ? 0 : usageBoost(usage(item.id))
            return Candidate(item: item, position: position, score: item.score + boost)
        }
        candidates.sort { a, b in
            if a.item.relevance != b.item.relevance { return a.item.relevance < b.item.relevance }
            if a.item.relevance == .fallback { return a.position < b.position }
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
        var ranked = candidates.map(\.item)
        if typed, RequestText.readsLikeRequest(query),
            let lead = ranked.firstIndex(where: { $0.relevance == .fallback }),
            case let length = Fold.query(query).count,
            !ranked.contains(where: { isStrong($0, queryLength: length) })
        {
            ranked.insert(ranked.remove(at: lead), at: 0)
        }
        return ranked
    }

    /// Exact and answer rows always are; a match when it scored well.
    static func isStrong(_ item: Item, queryLength: Int) -> Bool {
        switch item.relevance {
        case .exact, .answer: return true
        case .fallback: return false
        case .match:
            return item.score >= strongScorePerScalar * Double(queryLength)
        }
    }

    static func usageBoost(_ frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return min(maxUsageBoost, 6 * log2(1 + frecency))
    }
}
