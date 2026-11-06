import Foundation

/// Merges results from every root source into one order.
///
/// Relevance tiers come first (exact, answer, match, fallback). Within a tier three policies apply:
/// - **User order**: in the fallback tier, items whose origin is in `fallbackOrder` come first, in
///   that order. A fallback list is a fixed menu, so it never moves by habit.
/// - **Host-scored**: the host's own items (apps, files, calculator, built-ins) by score plus a
///   frecency boost (none for fallbacks), then (for a non-empty query) the shorter title, then name.
///   An empty query therefore lists by usage, then name.
/// - **Provider order**: extension items after the host's, one block per command (by extension
///   id, then command name), each in the order the command sent and never reordered by habit. The
///   host can judge how well its own items match the query but not an extension's, so an extension
///   that answers every query can't push the app the user typed off the top row; an extension that
///   is sure goes in a higher tier (`answer`).
public enum Ranker {
    /// Frecency adds at most this much, so habit breaks ties but never beats a clearly better match.
    static let maxUsageBoost = 18.0

    public static func rank(
        _ items: [Item], query: String, usage: (String) -> Double, fallbackOrder: [CommandID] = []
    ) -> [Item] {
        let typed = !Fold.query(query).isEmpty
        let listed = Dictionary(
            fallbackOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        struct Candidate {
            let item: Item
            /// Position in `fallbackOrder`, for listed fallbacks.
            let listed: Int?
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
            return Candidate(
                item: item, listed: fallback ? item.origin.flatMap { listed[$0] } : nil,
                provider: provider, position: position, score: item.score + boost)
        }
        candidates.sort { a, b in
            if a.item.relevance != b.item.relevance { return a.item.relevance < b.item.relevance }
            if a.listed != b.listed { return (a.listed ?? .max) < (b.listed ?? .max) }
            switch (a.provider, b.provider) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (.some(let pa), .some(let pb)):
                if pa != pb { return pa < pb }
                return a.position < b.position
            case (nil, nil):
                break
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
        return candidates.map(\.item)
    }

    static func usageBoost(_ frecency: Double) -> Double {
        guard frecency > 0 else { return 0 }
        return min(maxUsageBoost, 6 * log2(1 + frecency))
    }
}
