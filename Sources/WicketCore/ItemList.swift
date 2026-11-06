import Foundation

/// Items on screen and the selected one: the selection state any list shares, whoever orders it
/// (the root search ranks its items, a command's list keeps the command's order).
///
/// The selection follows the selected item's id when the items change, so a late result never
/// changes what Return runs. Two rules cover the cases where it can't:
/// - The selected item disappeared: the selection stays on the same row, clamped to the last one,
///   so the highlight never jumps (an emptied list selects nothing).
/// - Truncation never drops the selected item: if it would fall past `limit`, it takes the last
///   row instead of the item ranked there.
public struct ItemList: Sendable, Hashable {
    public private(set) var items: [Item] = []
    /// Row of the selected item; 0 while the list is empty.
    public private(set) var selection = 0
    public let limit: Int

    public init(_ items: [Item] = [], limit: Int = .max) {
        self.limit = limit
        replace(with: items, resettingSelection: true)
    }

    public var selectedItem: Item? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// Replaces the items, in order, keeping at most `limit`. The selection follows its item unless
    /// `resettingSelection`, which starts at the top (the user typed something new).
    public mutating func replace(with items: [Item], resettingSelection: Bool = false) {
        let keep = resettingSelection ? nil : selectedItem?.id
        var shown = Array(items.prefix(limit))
        if let keep, !shown.isEmpty, !shown.contains(where: { $0.id == keep }),
            let pinned = items.dropFirst(limit).first(where: { $0.id == keep })
        {
            shown[shown.count - 1] = pinned
        }
        let row = selection
        self.items = shown
        if let keep, let index = shown.firstIndex(where: { $0.id == keep }) {
            selection = index
        } else {
            selection = resettingSelection ? 0 : min(row, max(shown.count - 1, 0))
        }
    }

    public mutating func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }
}
