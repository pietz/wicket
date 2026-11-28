import Foundation
import Testing

@testable import WicketApp

@Test(arguments: ["\r\n", "\r"]) func crlfFencedCodeDoesNotCrash(newline: String) {
  let blocks = document(
    ["Heading", "", "```swift", "let x = 1", "```", "After"].joined(separator: newline)
  ).blocks
  #expect(blocks.map(\.renderedText) == ["Heading", "let x = 1", "After"])
}
@Test func completedAnswerKeepsUnfinishedTagLikeText() {
  #expect(text("use i<count in loop").contains("i<count in loop"))
  // While streaming, only what can still become a Wicket tag waits.
  #expect(text("use i<count in loop", streaming: true).contains("in loop"))
  #expect(!text("use <row title=\"A", streaming: true).contains("row"))
  #expect(!text("use <ch", streaming: true).contains("ch"))
}
@Test(arguments: [
  (#"Use \<Button>"#, "Use <Button>"),
  (#"Use \<button"#, "Use <button"),
  (
    #"Use \<Button label='**B** <row title="Literal" copy="no"/>'>"#,
    "Use <Button label='**B** <row title=\"Literal\" copy=\"no\"/>'>"
  ),
  ("<!-- <Button> -->", "<!-- <Button> -->"),
  (
    #"Use \<row title="Literal" copy="no"/>"#,
    "Use <row title=\"Literal\" copy=\"no\"/>"
  ),
  (
    #"Use <!-- <row title="Literal" copy="no"/> -->"#,
    "Use <!-- <row title=\"Literal\" copy=\"no\"/> -->"
  ),
  ("Use `<Button>`", "Use <Button>"),
])
func tagsInLiteralMarkdownContextsStayText(input: String, expected: String) {
  for streaming in [false, true] {
    let page = Page(body: input, runs: false, streaming: streaming)
    #expect(page.targets.isEmpty)
    #expect(page.source == input)
    #expect(text(page.source, streaming: streaming).trimmingCharacters(in: .newlines) == expected)
  }
}
@Test func tagsStillRenderAfterCommentsAndEscapedBackslashes() {
  let input = #"""
    - Use <!-- <badge label="Literal"/> --> <badge label="List"/>

    | Status |
    | --- |
    | \\<badge label="Table"/> |
    """#
  let page = Page(body: input, runs: false)
  let blocks = PageDocument(page, turn: "t", streaming: false).blocks
  #expect(blocks.map(\.renderedText) == [#"Use <!-- <badge label="Literal"/> --> List"#, "Status\n\\Table"])
}
@Test func largeTagInputHasBoundedProcessingCost() {
  let input =
    "<card" + String(repeating: " ", count: 12_000) + "<\n"
    + String(repeating: "<badge label=\"Ready\"/>", count: 4000)
  let start = ContinuousClock.now
  #expect(text(input).contains("Ready"))
  #expect(ContinuousClock.now - start < .seconds(1))
}

private func text(_ body: String, streaming: Bool = false) -> String {
  document(body, streaming: streaming).blocks.map(\.renderedText).joined(separator: "\n")
}
