import Foundation

/// Items on screen and the selected one: the selection state any list shares, whoever orders it
/// (the root search ranks its items, a command's list keeps the command's order, a document lists
/// its targets in reading order).
///
/// Until the user moves it, the selection is the top row (`selectsFirst`), so the best result is
/// always the one highlighted, even when better results arrive late; a document selects nothing
/// until the user moves (`selectsFirst` false), since its first target may be far down the page.
/// Once moved, it follows the chosen item's id when the items change, so a late result never
/// changes what Return runs. Two rules cover the cases where it can't:
/// - The selected item disappeared: the selection stays on the same row, clamped to the last one,
///   so the highlight never jumps (an emptied list selects nothing).
/// - Truncation never drops the selected item: if it would fall past `limit`, it takes the last
///   row instead of the item ranked there.
public struct ItemList: Sendable, Hashable {
    public private(set) var items: [Item] = []
    /// Row of the selected item; 0 while the list is empty or nothing is selected.
    public private(set) var selection = 0
    public let limit: Int
    /// Whether the top row is selected before the user moves; if not, nothing is.
    public let selectsFirst: Bool
    /// Whether the user moved the selection since the last reset; until then it stays on the top row.
    private var moved = false

    public init(_ items: [Item] = [], limit: Int = .max, selectsFirst: Bool = true) {
        self.limit = limit
        self.selectsFirst = selectsFirst
        replace(with: items, resettingSelection: true)
    }

    /// Whether a row is selected: always in a non-empty list that selects its first row, else only
    /// once the user moved.
    public var hasSelection: Bool { !items.isEmpty && (selectsFirst || moved) }

    public var selectedItem: Item? {
        hasSelection && items.indices.contains(selection) ? items[selection] : nil
    }

    /// Replaces the items, in order, keeping at most `limit`. The selection follows its item unless
    /// `resettingSelection`, which starts at the top (the user typed something new).
    public mutating func replace(with items: [Item], resettingSelection: Bool = false) {
        if resettingSelection { moved = false }
        let keep = moved ? selectedItem?.id : nil
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
            selection = moved ? min(row, max(shown.count - 1, 0)) : 0
        }
    }

    /// Moves the selection by `delta` rows, clamped. In a list that selects nothing at first, the
    /// first move down selects the top row, and moving up from it selects nothing again.
    public mutating func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        if !selectsFirst {
            if !moved {
                guard delta > 0 else { return }
                moved = true
                selection = min(delta - 1, items.count - 1)
                return
            }
            if selection + delta < 0 {
                moved = false
                selection = 0
                return
            }
        }
        moved = true
        selection = min(max(selection + delta, 0), items.count - 1)
    }
}
