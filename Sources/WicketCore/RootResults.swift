import Foundation

/// The root search's results: each source's latest items for the current query, ranked together
/// by `Ranker` into an `ItemList`, which owns the selection.
///
/// Late updates carry their query's generation and are dropped unless it is current. The selection
/// goes back to the top only when the query text changes; a refresh with the same text (a source's
/// data changed) keeps it.
public struct RootResults: Sendable {
    public private(set) var query = Query(text: "", generation: 0)
    public private(set) var list: ItemList
    private var bySource: [String: [Item]] = [:]
    /// The user's order for fallback commands; see `Ranker.rank`.
    private let fallbackOrder: [CommandID]

    public init(limit: Int = .max, fallbackOrder: [CommandID] = []) {
        list = ItemList(limit: limit)
        self.fallbackOrder = fallbackOrder
    }

    public var items: [Item] { list.items }
    public var selection: Int { list.selection }
    public var selectedItem: Item? { list.selectedItem }

    /// Starts `query` with each source's instant results, keyed by source id.
    public mutating func start(_ query: Query, results: [String: [Item]], usage: (String) -> Double) {
        let reset = query.text != self.query.text
        self.query = query
        bySource = results
        rerank(resettingSelection: reset, usage: usage)
    }

    /// Replaces everything `source` returned so far. Ignored, returning false, unless `generation` is
    /// the current query's.
    @discardableResult
    public mutating func update(
        _ source: String, items: [Item], generation: Int, usage: (String) -> Double
    ) -> Bool {
        guard generation == query.generation else { return false }
        bySource[source] = items
        rerank(resettingSelection: false, usage: usage)
        return true
    }

    public mutating func moveSelection(by delta: Int) {
        list.moveSelection(by: delta)
    }

    private mutating func rerank(resettingSelection: Bool, usage: (String) -> Double) {
        // Sorted by source id, so equal-ranked items never depend on dictionary order.
        let candidates = bySource.sorted { $0.key < $1.key }.flatMap(\.value)
        list.replace(
            with: Ranker.rank(candidates, query: query.text, usage: usage, fallbackOrder: fallbackOrder),
            resettingSelection: resettingSelection)
    }
}
