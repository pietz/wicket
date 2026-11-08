import Foundation

/// Merges results from every root source into one order.
///
/// Relevance tiers come first (exact, answer, match, fallback). Within a tier three policies
/// apply:
/// - **Fixed menu**: the host's fallback rows (`FallbackSource`: Run Agent) keep the order their
///   source gave, never moved by habit or by title.
/// - **Host-scored**: the host's other items (apps, files, calculator, built-ins) by score plus a
///   frecency boost, then (for a non-empty query) the shorter title, then name. An empty query
///   therefore lists by usage, then name.
/// - **Provider order**: extension items after the host's, one block per command (by extension
///   id, then command name), each in the order the command sent and never reordered by habit. The
///   host can judge how well its own items match the query but not an extension's, so an extension
///   that answers every query can't push the app the user typed off the top row; an extension that
///   is sure goes in a higher tier (`answer`).
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
            /// The extension and command of a provider-ordered item.
            let provider: (extension: String, command: String)?
            /// Position in the input, which is the provider's order.
            let position: Int
            let score: Double
        }
        var candidates = items.enumerated().map { position, item in
            let fallback = item.relevance == .fallback
            var provider: (String, String)?
            if case .extension(let id) = item.origin?.owner, let name = item.origin?.name {
                provider = (id, name)
            }
            let boost = fallback || provider != nil ? 0 : usageBoost(usage(item.id))
            return Candidate(item: item, provider: provider, position: position, score: item.score + boost)
        }
        candidates.sort { a, b in
            if a.item.relevance != b.item.relevance { return a.item.relevance < b.item.relevance }
            switch (a.provider, b.provider) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (.some(let pa), .some(let pb)):
                if pa != pb { return pa < pb }
                return a.position < b.position
            case (nil, nil):
                if a.item.relevance == .fallback { return a.position < b.position }
            }
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

    /// Exact and answer rows always are. A match is when the host scored it well; an
    /// extension's match can't be judged (a sure extension answers in the `answer` tier).
    static func isStrong(_ item: Item, queryLength: Int) -> Bool {
        switch item.relevance {
        case .exact, .answer: return true
        case .fallback: return false
        case .match:
            if case .extension = item.origin?.owner { return false }
            return item.score >= strongScorePerScalar * Double(queryLength)
        }
    }

    static func usageBoost(_ frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return min(maxUsageBoost, 6 * log2(1 + frecency))
    }
}
