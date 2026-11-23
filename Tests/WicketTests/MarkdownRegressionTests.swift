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
@Test(arguments: [
  (#"Use \<Button>"#, "<p>Use &lt;Button&gt;</p>"),
  (#"Use \<button"#, "<p>Use &lt;button</p>"),
  (
    #"Use \<Button label='**B** <row title="Literal" copy="no"/>'>"#,
    "<p>Use &lt;Button label='**B** &lt;row title=&quot;Literal&quot; copy=&quot;no&quot;/&gt;'&gt;</p>"
  ),
  ("<!-- <Button> -->", "<p>&lt;!-- &lt;Button&gt; --&gt;\n</p>"),
  (
    #"Use \<row title="Literal" copy="no"/>"#,
    "<p>Use &lt;row title=&quot;Literal&quot; copy=&quot;no&quot;/&gt;</p>"
  ),
  (
    #"Use <!-- <row title="Literal" copy="no"/> -->"#,
    "<p>Use &lt;!-- &lt;row title=&quot;Literal&quot; copy=&quot;no&quot;/&gt; --&gt;</p>"
  ),
  ("Use `<Button>`", "<p>Use <code>&lt;Button&gt;</code></p>"),
])
func tagsInLiteralMarkdownContextsStayText(input: String, expected: String) {
  for streaming in [false, true] {
    let page = Page(body: input, runs: false, streaming: streaming)
    #expect(page.targets.isEmpty)
    #expect(page.source == input)
    #expect(AnswerMarkdown.html(page.source, streaming: streaming) == expected + "\n")
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
  let html = AnswerMarkdown.html(page.source)
  #expect(
    html.contains(
      #"<li>Use &lt;!-- &lt;badge label=&quot;Literal&quot;/&gt; --&gt; <w-badge data-label="List""#))
  #expect(html.contains(#"<td>\<w-badge data-label="Table""#))
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
