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
  static let componentNames = ["row", "tile", "progress", "badge", "columns", "card", "chart"]
  static let shapeNames = Set(
    componentNames + ["tileInColumns", "cardInColumns", "rowDetail", "copyRow", "headline", "contextLine"])

  init(_ reply: String, question: EvalQuestion) {
    let expectation = question.expect
    let page = Page(body: reply, runs: false)
    let blocks = PageDocument(page, turn: "eval", streaming: false).blocks
    let opensWithHeadline = if case .heading(1, _) = blocks.first { true } else { false }
    let opensWithParagraph = if case .paragraph = blocks.first { true } else { false }
    let lead =
      opensWithHeadline || opensWithParagraph
      ? String(blocks.first?.renderedText.split(separator: "\n").first ?? "") : ""
    let count = Self.wordCount(lead)
    // A short noun phrase can be the result ("Titan"). Reject headings that repeat the question's topic.
    let questionWords = Set(Self.topicWords(question.question))
    let specific = Self.topicWords(lead).contains { !questionWords.contains($0) }
    // Restating the question is never the answer, whatever digits or verbs it contains.
    let restated = Self.normalized(lead) == Self.normalized(question.question)
    // An answer that opens with a component (tiles, a draft card) is the result itself.
    let opensWithComponent = blocks.first.map { !($0.isProse) } ?? false
    let result =
      opensWithComponent
      || !restated && (1...18).contains(count)
        && (lead.contains(where: \.isNumber)
          || lead.contains(/(?i)\b(?:is|are|was|were|has|have|can|use|pick|choose|start|keep|yes|no)\b/)
          || lead.hasSuffix(".") || lead.hasSuffix("!") || (count <= 8 && specific))
    answerFirst = result
    answerFirstPoints = result ? 20 : 0

    var parts = Dictionary(uniqueKeysWithValues: Self.componentNames.map { ($0, 0) })
    var rowIDs: Set<String> = []
    var headingCount = 0
    var itemCount = 0
    var paragraphCount = 0
    var tableCount = 0
    func visit(_ block: PageBlock, cardTitle: Bool = false) {
      switch block {
      case .rows(let rows), .properties(let rows):
        parts["row", default: 0] += rows.count
        rowIDs.formUnion(rows.compactMap(\.target))
      case .tile: parts["tile", default: 0] += 1
      case .progresses(let bars): parts["progress", default: 0] += bars.count
      case .badges(let badges): parts["badge", default: 0] += badges.count
      case .chart: parts["chart", default: 0] += 1
      case .card: parts["card", default: 0] += 1
      case .columns(let cells, _):
        parts["columns", default: 0] += 1
        let tiles = cells.count { if case .tile = $0 { true } else { false } }
        let cards = cells.count { if case .card = $0 { true } else { false } }
        parts["tileInColumns"] = max(parts["tileInColumns", default: 0], tiles)
        parts["cardInColumns"] = max(parts["cardInColumns", default: 0], cards)
      case .heading(let level, _) where level > 1 && !cardTitle: headingCount += 1
      case .paragraph(let text):
        paragraphCount += Self.wordCount(text.plain) > Self.longParagraphWords ? 1 : 0
        parts["badge", default: 0] += text.runs.count { if case .badge = $0 { true } else { false } }
      case .list(_, _, let items): itemCount += items.count
      case .table: tableCount += 1
      default: break
      }
      let card = if case .card = block { true } else { false }
      for (index, child) in block.children.enumerated() {
        visit(child, cardTitle: card && index == 0)
      }
    }
    for block in blocks { visit(block) }
    parts["rowDetail"] = page.targets.count { row in
      rowIDs.contains(row.id) && row.actions.contains { if case .detail = $0.kind { true } else { false } }
    }
    parts["copyRow"] = page.targets.count { row in
      rowIDs.contains(row.id) && row.actions.contains { if case .copy = $0.kind { true } else { false } }
    }
    parts["headline"] = result && opensWithHeadline ? 1 : 0
    if opensWithHeadline, blocks.count > 1, case .paragraph(let text) = blocks[1], !text.plain.contains("\n")
    {
      parts["contextLine"] = (1...20).contains(Self.wordCount(text.plain)) ? 1 : 0
    } else {
      parts["contextLine"] = 0
    }
    components = parts

    shapeMaximum = 55
    let coverage = expectation.minimum.reduce(0.0) { sum, goal in
      sum + Double(min(parts[goal.key, default: 0], goal.value)) / Double(goal.value)
    }
    shapePoints = Int((55 * coverage / Double(max(1, expectation.minimum.count))).rounded())

    headings = headingCount
    listItems = itemCount
    longParagraphs = paragraphCount
    tables = tableCount
    markdownPoints = max(0, 15 - headings * 3 - listItems * 2 - longParagraphs * 4 - tables * 8)
    words = Self.wordCount(blocks.map(\.renderedText).joined(separator: " "))
    characters = reply.count
    lengthPoints = words > 0 ? min(10, 10 * expectation.maxWords / words) : 0
    total = words > 0 ? shapePoints + answerFirstPoints + markdownPoints + lengthPoints : 0
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
