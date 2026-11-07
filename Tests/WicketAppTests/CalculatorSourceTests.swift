import Testing
import WicketCore

@testable import WicketApp

/// Return copies the answer and the second action pastes it back; a message offers neither.
@MainActor
@Test func calculatorRowCopiesThenPastesTheResult() throws {
    let source = CalculatorSource()
    let row = try #require(source.instant(Query(text: "6 * 7", generation: 1)).first)
    #expect(row.title == "42")
    #expect(row.actions == [.copy(text: "42", title: "Copy Result"), .paste(text: "42")])

    let message = try #require(source.instant(Query(text: "1 / 0", generation: 2)).first)
    #expect(message.title == "Can't divide by zero")
    #expect(message.actions.isEmpty)
}
