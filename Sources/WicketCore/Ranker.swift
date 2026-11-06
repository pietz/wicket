import Foundation

/// One rankable entry: a primary name plus optional alternates (file name, English name).
public struct Candidate: Sendable {
    public let id: String
    public let title: String
    public let keys: [SearchKey]

    public init(id: String, title: String, alternates: [String] = []) {
        self.id = id
        self.title = title
        var names = [title]
        for alternate in alternates where Fold.fold(alternate) != Fold.fold(title) {
            names.append(alternate)
        }
        self.keys = names.map(SearchKey.init)
    }
}

public enum Ranker {
    /// Frecency adds at most this much, so habit breaks ties but never beats a clearly better match.
    static let maxUsageBoost = 18.0

    /// Indices of matching candidates, best first. An empty query sorts everything by usage, then name.
    public static func rank(
        query: String, candidates: [Candidate], usage: (String) -> Double, limit: Int = .max
    ) -> [Int] {
        let folded = Fold.query(query)
        var scored: [(index: Int, score: Double)] = []
        scored.reserveCapacity(candidates.count)

        for (index, candidate) in candidates.enumerated() {
            let boost = usageBoost(usage(candidate.id))
            if folded.isEmpty {
                scored.append((index, boost))
                continue
            }
            var best: Int?
            for (keyIndex, key) in candidate.keys.enumerated() {
                guard var s = FuzzyMatcher.score(folded, key) else { continue }
                if keyIndex > 0 { s -= 1 }  // the displayed name wins ties against an alternate
                best = max(best ?? s, s)
            }
            if let best { scored.append((index, Double(best) + boost)) }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ta = candidates[a.index].title, tb = candidates[b.index].title
            if ta.count != tb.count, !folded.isEmpty { return ta.count < tb.count }
            return ta.localizedStandardCompare(tb) == .orderedAscending
        }
        return scored.prefix(limit).map(\.index)
    }

    static func usageBoost(_ frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return min(maxUsageBoost, 6 * log2(1 + frecency))
    }
}
