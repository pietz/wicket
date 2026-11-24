import Foundation
import Testing

@testable import WicketApp

private func question(_ id: String) throws -> EvalQuestion {
  try #require(try EvalQuestion.load().first { $0.id == id })
}

@Test func evalQuestionFixtureHasUniqueIDsAndScorableShapes() throws {
  let questions = try EvalQuestion.load()
  #expect(questions.count == 33)
  #expect(Set(questions.map(\.id)).count == questions.count)
  #expect(Set(questions.map(\.category)).count == 8)
  for question in questions {
    #expect(question.id.wholeMatch(of: /[a-z0-9]+(?:-[a-z0-9]+)*/) != nil)
    #expect(question.expect.maxWords > 0)
    #expect(question.expect.minimum.keys.allSatisfy(EvalScore.shapeNames.contains))
    #expect(!question.expect.minimum.isEmpty)
    #expect(question.expect.minimum.values.allSatisfy { $0 > 0 })
  }
}

@Test func evalScoreRewardsTheExpectedShapes() throws {
  let fact = EvalScore(
    "# Titan\n\nIt is also the second-largest moon in the Solar System.",
    question: try question("titan"))
  #expect(fact.total == 100)
  #expect(fact.answerFirst == true)
  #expect(fact.components["headline"] == 1)
  #expect(fact.components["contextLine"] == 1)
  let topic = EvalScore("# Saturn’s largest moon\n\nTitan.", question: try question("titan"))
  #expect(topic.answerFirst == false)
  #expect(topic.total < fact.total)

  let comparison = try question("png-jpeg")
  let cards = EvalScore(
    """
    Use PNG for the screenshot.
    <columns>
    <card>
    ## PNG
    <row label="Text" value="Sharp"/>
    </card>
    <card>
    ## JPEG
    <row label="Text" value="Visible compression"/>
    </card>
    </columns>
    """, question: comparison)
  #expect(cards.components["card"] == 2)
  #expect(cards.components["cardInColumns"] == 2)
  #expect(cards.total == 100)
  let markdown = EvalScore(
    """
    ## PNG vs JPEG

    - PNG for fine text
    - JPEG for photos

    | Format | Text |
    | --- | --- |
    | PNG | Sharp |

    \(String(repeating: "Long explanation ", count: 24))
    """, question: comparison)
  #expect(markdown.headings == 1)
  #expect(markdown.listItems == 2)
  #expect(markdown.tables == 1)
  #expect(markdown.longParagraphs == 1)
  #expect(markdown.markdownPoints == 0)
  #expect(markdown.total < cards.total)
}

@Test func evalScoreUsesVisibleComponentsAndRecognizesRowDetails() throws {
  let score = EvalScore(
    """
    Start with a sheet of paper.
    <row title="Fold in half">
    ## Crease
    Fold the sheet lengthwise and reopen it.
    </row>
    <row title="Corners" open="https://example.com" ask="More?"/>
    ```text
    <row title="Example only"/>
    ## Printed code
    ```
    """, question: try question("paper-airplane"))
  #expect(score.components["row"] == 1)
  #expect(score.components["rowDetail"] == 1)
  #expect(score.headings == 0)
  #expect(score.answerFirst == true)

  let card = EvalScore(
    """
    Draft for Thursday.
    <card>
    ## Cedar
    <row label="Starts" value="10:00"/>
    </card>
    """, question: try question("room-booking"))
  #expect(card.components["card"] == 1)
  #expect(card.headings == 0)
}

@Test func evalScoreExpectsWritingInACardWithACopyRow() throws {
  let writing = try question("late-note")
  let text = "Running ten minutes late. Please start without me if that helps."
  let card = EvalScore(
    """
    <card icon="bubble.left">
    ## Note
    \(text)
    </card>
    <row icon="doc.on.doc" title="Copy note" copy="\(text)"/>
    """, question: writing)
  #expect(card.answerFirst == true)
  #expect(card.components["copyRow"] == 1)
  #expect(card.total == 100)
  let inert = EvalScore(
    "<card>\n## Note\n\(text)\n</card>\n<row title=\"Copy note\"/>", question: writing)
  #expect(inert.components["copyRow"] == 0)
  #expect(inert.total < card.total)
  let split = EvalScore(
    "Use PNG.\n<columns>\n<card>\n## PNG\n</card>\n</columns>\n<columns>\n<card>\n## JPEG\n</card>\n</columns>",
    question: try question("png-jpeg"))
  #expect(split.components["cardInColumns"] == 1)
  // Earlier results left `answerFirst` out for writing tasks; they must still load as a baseline.
  var stored = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
  stored["answerFirst"] = nil
  let old = try JSONDecoder().decode(EvalScore.self, from: JSONSerialization.data(withJSONObject: stored))
  #expect(old.answerFirst == nil)
  #expect(EvalScore(text, question: writing).total <= 45)
  #expect(EvalScore("", question: writing).total == 0)
  let long = EvalScore(String(repeating: "Words and words. ", count: 60), question: writing)
  #expect(long.longParagraphs == 1)
  #expect(long.markdownPoints == 11)
  #expect(long.lengthPoints < card.lengthPoints)
}

@MainActor
@Test func evalReportFixture() async throws {
  let export = ProcessInfo.processInfo.environment["WICKET_EVAL_FIXTURE_DIR"]
  let directory = try export.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? scratch()
  defer { if export == nil { try? FileManager.default.removeItem(at: directory) } }
  let question = try question("disk-quota")
  var old = EvalCandidate(variant: "current", agent: "claude-sonnet", question: question)
  old.reply = "## Disk usage\n\n- 16 GB free\n- 22 GB needed"
  old.score = EvalScore(try #require(old.reply), question: question)
  old.judge = .init(score: 2, comment: "Show capacity in a bar.")
  var current = old
  current.reply = """
    No — the export needs 6 GB more. <badge label="Insufficient" tone="warning"/>
    <progress label="Scratch disk" value="184 of 200 GB" percent="92"/>
    """
  let reply = try #require(current.reply)
  current.score = EvalScore(reply, question: question)
  current.light = current.id + "-light.png"
  current.judge = .init(score: 4, comment: "Keep the label < 20 characters & lead with the shortfall.")
  var alternate = EvalCandidate(variant: "alternative", agent: "claude-sonnet", question: question)
  alternate.reply = old.reply
  alternate.score = old.score
  alternate.judge = old.judge
  alternate.light = alternate.id + "-light.png"
  var failed = EvalCandidate(variant: "current", agent: "codex-test", question: question)
  failed.failures = ["Turn timed out."]
  let candidates = [current, alternate, failed]
  if export != nil {
    for candidate in candidates {
      guard let light = candidate.light, let text = candidate.reply else { continue }
      let image = directory.appending(path: light)
      try FileManager.default.createDirectory(
        at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await renderReply((question.question, text), dark: false, to: image)
    }
  }
  try EvalReport.write(candidates, baseline: [old], to: directory)
  let html = try String(contentsOf: directory.appending(path: "report.html"), encoding: .utf8)
  #expect(html.contains("src=\"current/claude-sonnet/disk-quota-light.png\""))
  #expect(html.contains("Judge 4/5 (Δ +2)"))
  #expect(html.contains("&lt; 20 characters &amp; lead"))
  #expect(html.contains("Turn timed out."))
  #expect(html.contains("Status and checks"))
  #expect(html.components(separatedBy: "My scratch disk has used").count == 2)
  let results = try JSONDecoder().decode(
    [EvalCandidate].self,
    from: Data(contentsOf: directory.appending(path: "results.json")))
  #expect(results.map(\.id) == candidates.map(\.id))
  #expect(results[0].judge?.score == 4)
  #expect(results[0].reply == current.reply)
  let pairs = try JSONDecoder().decode(
    [JSONValue].self,
    from: Data(contentsOf: directory.appending(path: "pairs.json")))
  #expect(pairs.count == 1)
  let pair = try #require(pairs.first)
  #expect(pair["id"].string == "disk-quota")
  #expect(pair["candidates"].array.compactMap { $0["id"].string } == [current.id, alternate.id])
  #expect(pair["candidates"].array.first?["id"].string == current.id)
  #expect(pair["candidates"].array.first?["light"].string == current.light)
}

@Test func evalScoreNeverCountsTheRestatedQuestionAsTheAnswer() throws {
  let seconds = try question("seconds")
  let restated = EvalScore("# \(seconds.question)\n9,000 seconds.", question: seconds)
  #expect(restated.answerFirst == false)
  #expect(restated.components["headline"] == 0)
  #expect(restated.total < 100)
}
