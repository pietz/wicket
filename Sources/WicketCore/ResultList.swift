import Foundation

/// The results on screen: each source's latest items for the current query, ranked together.
///
/// The selection follows the selected item's id when results change, so a late result never
/// changes what Return runs. It goes back to the top only when the query text changes.
public struct ResultList: Sendable {
    public private(set) var query = Query(text: "", revision: 0)
    public private(set) var items: [Item] = []
    public private(set) var selection = 0
    private var bySource: [String: [Item]] = [:]
    private let limit: Int

    public init(limit: Int = .max) {
        self.limit = limit
    }

    public var selectedItem: Item? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// Starts `query` with each source's instant results, keyed by source id.
    public mutating func start(_ query: Query, results: [String: [Item]], usage: (String) -> Double) {
        let keep = query.text == self.query.text ? selectedItem?.id : nil
        self.query = query
        bySource = results
        rerank(keeping: keep, usage: usage)
    }

    /// Replaces everything `source` returned so far. Ignored, returning false, unless `revision` is
    /// the current query's.
    @discardableResult
    public mutating func update(
        _ source: String, items: [Item], revision: Int, usage: (String) -> Double
    ) -> Bool {
        guard revision == query.revision else { return false }
        bySource[source] = items
        rerank(keeping: selectedItem?.id, usage: usage)
        return true
    }

    public mutating func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    private mutating func rerank(keeping id: String?, usage: (String) -> Double) {
        items = Ranker.rank(bySource.values.flatMap(\.self), query: query.text, usage: usage, limit: limit)
        selection = id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }
}
