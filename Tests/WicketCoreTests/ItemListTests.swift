import Foundation
import Testing

@testable import WicketCore

private func items(_ titles: String...) -> [Item] {
    titles.map { Item(id: $0, title: $0, icon: .symbol(name: "doc"), actions: []) }
}

private func titles(_ list: ItemList) -> [String] { list.items.map(\.title) }

@Test func selectionFollowsItsItem() {
    var list = ItemList(items("A", "B", "C"))
    list.moveSelection(by: 1)
    list.replace(with: items("New", "A", "B", "C"))
    #expect(list.selectedItem?.title == "B")
    list.replace(with: items("C", "B"))
    #expect(list.selection == 1)
}

@Test func aVanishedSelectionStaysOnItsRow() {
    var list = ItemList(items("A", "B", "C", "D"))
    list.moveSelection(by: 2)
    list.replace(with: items("A", "B", "D"))
    #expect(list.selectedItem?.title == "D")
    // Clamped to the last row when the list got shorter than the selection.
    list.replace(with: items("X"))
    #expect(list.selectedItem?.title == "X")
    list.replace(with: [])
    #expect(list.selectedItem == nil)
    #expect(list.selection == 0)
    list.replace(with: items("Y", "Z"))
    #expect(list.selectedItem?.title == "Y")
}

@Test func anUntouchedSelectionStaysOnTop() {
    // A late, better result takes the highlight unless the user chose a row.
    var list = ItemList(items("Run Agent"))
    list.replace(with: items("AGENTS.md", "Run Agent"))
    #expect(list.selectedItem?.title == "AGENTS.md")
}

@Test func resettingStartsAtTheTop() {
    var list = ItemList(items("A", "B"))
    list.moveSelection(by: 1)
    list.replace(with: items("A", "B"), resettingSelection: true)
    #expect(list.selection == 0)
}

@Test func truncationKeepsTheSelectedItem() {
    var list = ItemList(items("A", "B", "C"), limit: 3)
    list.moveSelection(by: 2)
    list.replace(with: items("X", "A", "B", "C"))
    #expect(titles(list) == ["X", "A", "C"])
    #expect(list.selectedItem?.title == "C")
    // Unselected rows are simply cut.
    list.moveSelection(by: -2)
    list.replace(with: items("Y", "X", "A", "B"))
    #expect(titles(list) == ["Y", "X", "A"])
    #expect(list.selectedItem?.title == "X")
}

@Test func movingStopsAtTheEnds() {
    var list = ItemList(items("A", "B"))
    list.moveSelection(by: -1)
    #expect(list.selection == 0)
    list.moveSelection(by: 5)
    #expect(list.selection == 1)
    var empty = ItemList()
    empty.moveSelection(by: 1)
    #expect(empty.selectedItem == nil)
}
