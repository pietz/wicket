import Foundation
import Testing

@testable import WicketApp

@Test(arguments: ["\r\n", "\r"]) func crlfFencedCodeDoesNotCrash(newline: String) {
  let html = AnswerMarkdown.html(
    ["Heading", "", "```swift", "let x = 1", "```", "After"].joined(separator: newline))
  #expect(html.contains("let x = 1"))
  #expect(html.contains("After"))
}
@Test func completedAnswerKeepsUnfinishedTagLikeText() {
  #expect(AnswerMarkdown.html("use i<count in loop").contains("i&lt;count in loop"))
  #expect(!AnswerMarkdown.html("use i<count in loop", streaming: true).contains("count"))
}
@Test func largeTagInputHasBoundedProcessingCost() {
  let input =
    "<card" + String(repeating: " ", count: 12_000) + "<\n"
    + String(repeating: "<badge label=\"Ready\"/>", count: 4000)
  let start = ContinuousClock.now
  let html = AnswerMarkdown.html(input)
  #expect(html.contains("Ready"))
  #expect(ContinuousClock.now - start < .seconds(1))
}
