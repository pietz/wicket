import Foundation

/// Fuzzy search over items known up front, for memory-only sources such as apps and commands.
/// Search keys are prepared once here, so a keystroke only folds the query and runs the matcher.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let item: Item
        /// The title first, then alternates such as the file name or English name.
        let keys: [SearchKey]
    }

    private let entries: [Entry]

    public init(_ items: [(item: Item, alternates: [String])]) {
        entries = items.map { item, alternates in
            var names = [item.title]
            for alternate in alternates where Fold.fold(alternate) != Fold.fold(item.title) {
                names.append(alternate)
            }
            return Entry(item: item, keys: names.map(SearchKey.init))
        }
    }

    /// Matching items with relevance and score set. An empty query returns every item, unscored.
    public func search(_ text: String) -> [Item] {
        let query = Fold.query(text)
        guard !query.isEmpty else { return entries.map(\.item) }
        var results: [Item] = []
        for entry in entries {
            var best: Int?
            var exact = false
            for (index, key) in entry.keys.enumerated() {
                guard var score = FuzzyMatcher.score(query, key) else { continue }
                if key.compact == query { exact = true }
                if index > 0 { score -= 1 }  // the displayed name wins ties against an alternate
                best = max(best ?? score, score)
            }
            guard let best else { continue }
            var item = entry.item
            item.relevance = exact ? .exact : .match
            item.score = Double(best)
            results.append(item)
        }
        return results
    }
}
