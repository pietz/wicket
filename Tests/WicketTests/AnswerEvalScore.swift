import Foundation

@testable import WicketApp

struct EvalQuestion: Codable, Equatable, Sendable {
  struct Expectation: Codable, Equatable, Sendable {
    let shape: String
    let minimum: [String: Int]
    let maxWords: Int
  }

  let id: String
  let question: String
  let category: String
  let expect: Expectation

  static func load() throws -> [Self] {
    try JSONDecoder().decode([Self].self, from: Data(contentsOf: fixtureURL("answer-eval.json")))
  }
}

struct EvalScore: Codable, Sendable {
  let total: Int
  let components: [String: Int]
  let shapePoints: Int
  let shapeMaximum: Int
  // Optional so earlier results.json files, which left it out for writing tasks, still load as a baseline.
  let answerFirst: Bool?
  let answerFirstPoints: Int
  let headings: Int
  let listItems: Int
  let longParagraphs: Int
  let tables: Int
  let markdownPoints: Int
  let words: Int
  let characters: Int
  let lengthPoints: Int

  static let longParagraphWords = 40
  static let componentNames = ["row", "tile", "progress", "badge", "columns", "card"]
  static let shapeNames = Set(
    componentNames + ["tileInColumns", "cardInColumns", "rowDetail", "copyRow", "headline", "contextLine"])

  init(_ reply: String, question: EvalQuestion) {
    let expectation = question.expect
    let page = Page(body: reply, runs: false)
    let html = AnswerMarkdown.html(page.source)
    let opening = html.prefixMatch(of: /\s*<(p|h1)>([\s\S]*?)<\/(?:p|h1)>/)
    let lead = Self.plain(String(opening?.2.split(separator: "\n").first ?? ""))
    let count = Self.wordCount(lead)
    // A short noun phrase can be the result ("Titan"). Reject headings that repeat the question's topic.
    let questionWords = Set(Self.topicWords(question.question))
    let specific = Self.topicWords(lead).contains { !questionWords.contains($0) }
    // Restating the question is never the answer, whatever digits or verbs it contains.
    let restated = Self.normalized(lead) == Self.normalized(question.question)
    // An answer that opens with a component (tiles, a draft card) is the result itself.
    let opensWithComponent = html.prefixMatch(of: /\s*<w-/) != nil
    let result =
      opensWithComponent
      || !restated && (1...18).contains(count)
        && (lead.contains(where: \.isNumber)
          || lead.contains(/(?i)\b(?:is|are|was|were|has|have|can|use|pick|choose|start|keep|yes|no)\b/)
          || lead.hasSuffix(".") || lead.hasSuffix("!") || (count <= 8 && specific))
    answerFirst = result
    answerFirstPoints = result ? 20 : 0

    var parts = Dictionary(
      uniqueKeysWithValues: Self.componentNames.map { name in
        (name, html.ranges(of: "<w-\(name) ").count)
      })
    let columns = html.matches(of: /(?s)<w-columns\b[^>]*>(.*?)<\/w-columns>/)
    // Side by side means within one columns block, not one item in each of several.
    parts["tileInColumns"] = columns.map { $0.1.ranges(of: "<w-tile ").count }.max() ?? 0
    parts["cardInColumns"] = columns.map { $0.1.ranges(of: "<w-card ").count }.max() ?? 0
    let rows = html.matches(of: /<w-row\b[^>]*\sdata-target="([^"]+)"/)
    let rowIDs = Set(rows.map { String($0.1) })
    parts["rowDetail"] =
      page.targets.filter { row in
        rowIDs.contains(row.id) && row.actions.contains { if case .detail = $0.kind { true } else { false } }
      }.count
    parts["copyRow"] =
      page.targets.filter { row in
        rowIDs.contains(row.id) && row.actions.contains { if case .copy = $0.kind { true } else { false } }
      }.count
    parts["headline"] = result && opening?.1 == "h1" ? 1 : 0
    if let opening, opening.1 == "h1",
      let next = html[opening.range.upperBound...].prefixMatch(
        of: /\s*<p>([^\n]+)<\/p>/)
    {
      parts["contextLine"] = (1...20).contains(Self.wordCount(Self.plain(String(next.1)))) ? 1 : 0
    } else {
      parts["contextLine"] = 0
    }
    components = parts

    shapeMaximum = 55
    let coverage = expectation.minimum.reduce(0.0) { sum, goal in
      sum + Double(min(parts[goal.key, default: 0], goal.value)) / Double(goal.value)
    }
    shapePoints = Int((55 * coverage / Double(max(1, expectation.minimum.count))).rounded())

    let markdown = html.replacing(/(?s)<w-card\b[^>]*>\s*<h2>.*?<\/h2>/, with: "<w-card>")
    headings = markdown.matches(of: /<h[2-6]>/).count
    listItems = markdown.matches(of: /<li>/).count
    longParagraphs = markdown.matches(of: /(?s)<p>(.*?)<\/p>/).count {
      Self.wordCount(Self.plain(String($0.1))) > Self.longParagraphWords
    }
    tables = markdown.ranges(of: "<table>").count
    markdownPoints = max(0, 15 - headings * 3 - listItems * 2 - longParagraphs * 4 - tables * 8)
    words = Self.wordCount(Self.plain(html))
    characters = reply.count
    lengthPoints = words > 0 ? min(10, 10 * expectation.maxWords / words) : 0
    total = words > 0 ? shapePoints + answerFirstPoints + markdownPoints + lengthPoints : 0
  }

  private static func plain(_ html: String) -> String {
    html.replacing(/<[^>]*>/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalized(_ string: String) -> String {
    string.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
  }

  private static func wordCount(_ string: String) -> Int {
    string.split(whereSeparator: \.isWhitespace).count
  }

  private static func topicWords(_ string: String) -> [Substring] {
    let generic: Set<Substring> = [
      "a", "an", "the", "in", "on", "at", "of", "and", "to", "for",
      "answer", "overview", "summary", "comparison", "recommendation", "options", "steps", "status", "result",
    ]
    return string.lowercased().split { !$0.isLetter && $0 != "’" }.filter { !generic.contains($0) }
  }
}
