import Foundation

@testable import WicketApp

struct EvalCandidate: Codable, Sendable {
  struct Judge: Codable, Sendable {
    let score: Int
    let comment: String
  }

  let variant: String
  let agent: String
  let question: EvalQuestion
  let id: String
  var reply: String?
  var score: EvalScore?
  var light: String?
  var dark: String?
  var judge: Judge?
  var darkJudge: Judge?
  var failures: [String] = []

  init(variant: String, agent: String, question: EvalQuestion) {
    self.variant = variant
    self.agent = agent
    self.question = question
    id = "\(variant)/\(agent)/\(question.id)"
  }

  var group: String { "\(variant) · \(agent)" }
}

struct EvalReport {
  private struct Pair: Encodable {
    struct Candidate: Encodable {
      let id: String
      let variant: String
      let agent: String
      let light: String
      let dark: String?
    }
    let id: String
    let question: String
    let candidates: [Candidate]
  }

  static func write(
    _ results: [EvalCandidate], baseline: [EvalCandidate] = [], to directory: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func save<T: Encodable>(_ value: T, as file: String) throws {
      try encoder.encode(value).write(to: directory.appending(path: file), options: .atomic)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try save(results, as: "results.json")
    let groups = Dictionary(grouping: results, by: \.question.id)
    let pairs = ordered(results.map(\.question.id)).compactMap { id -> Pair? in
      guard let matches = groups[id], let question = matches.first?.question else { return nil }
      let candidates = matches.compactMap { result in
        result.light.map {
          Pair.Candidate(
            id: result.id, variant: result.variant, agent: result.agent, light: $0, dark: result.dark)
        }
      }
      return Pair(id: id, question: question.question, candidates: candidates)
    }
    try save(pairs, as: "pairs.json")
    try Data(html(results, baseline: baseline).utf8)
      .write(to: directory.appending(path: "report.html"), options: .atomic)
  }

  private static func ordered(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }

  static func html(_ results: [EvalCandidate], baseline: [EvalCandidate]) -> String {
    let previous = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(grouping: results, by: \.group)
    let categories = ordered(results.map(\.question.category))
    func prior(_ candidate: EvalCandidate) -> EvalCandidate? {
      guard let old = previous[candidate.id], old.question == candidate.question else { return nil }
      return old
    }
    func average(_ scores: [Int]) -> String {
      scores.isEmpty ? "—" : String(format: "%.1f", Double(scores.reduce(0, +)) / Double(scores.count))
    }
    func delta(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    func summaryRow(_ group: String, _ category: String, _ candidates: [EvalCandidate]) -> String {
      let scores = candidates.compactMap(\.score?.total)
      let judges = candidates.compactMap(\.judge?.score)
      let deltas = candidates.compactMap { candidate -> Int? in
        guard let now = candidate.score?.total, let then = prior(candidate)?.score?.total else { return nil }
        return now - then
      }
      let judgeDeltas = candidates.compactMap { candidate -> Int? in
        guard let now = candidate.judge?.score, let then = prior(candidate)?.judge?.score else { return nil }
        return now - then
      }
      let difference = baseline.isEmpty ? "" : "<td>\(average(deltas)) (\(deltas.count))</td>"
      let judgeDifference = baseline.isEmpty ? "" : "<td>\(average(judgeDeltas)) (\(judgeDeltas.count))</td>"
      return """
        <tr><th scope="row">\(escape(group))</th><td>\(escape(category))</td>
        <td>\(scores.count)/\(candidates.count)</td><td>\(average(scores))</td>\(difference)
        <td>\(average(judges))</td>\(judgeDifference)</tr>
        """
    }
    let summaries = ordered(results.map(\.group)).flatMap { group -> [String] in
      let all = groups[group, default: []]
      return [summaryRow(group, "All", all)]
        + categories.compactMap { category in
          let candidates = all.filter { $0.question.category == category }
          return candidates.isEmpty ? nil : summaryRow(group, category, candidates)
        }
    }.joined(separator: "\n")
    let byQuestion = Dictionary(grouping: results, by: \.question.id)
    let rows = ordered(results.map(\.question.id)).compactMap { id -> String? in
      guard let candidates = byQuestion[id], let question = candidates.first?.question else { return nil }
      let cells = candidates.map { candidate in
        let image =
          candidate.light.map {
            "<a href=\"\(escape($0))\"><img loading=\"lazy\" src=\"\(escape($0))\" alt=\"Light Wicket answer\"></a>"
          } ?? "<p>No render</p>"
        let dark = candidate.dark.map { "<a href=\"\(escape($0))\">Dark render</a>" } ?? ""
        let raw =
          candidate.reply.map { "<details><summary>Reply text</summary><pre>\(escape($0))</pre></details>" }
          ?? ""
        let failures = candidate.failures.map { "<p>\(escape($0))</p>" }.joined()
        var metrics = "<p>No score</p>"
        if let score = candidate.score {
          let shape = score.components.keys.sorted().compactMap { key -> String? in
            let found = score.components[key, default: 0]
            let target = question.expect.minimum[key]
            guard found > 0 || target != nil else { return nil }
            return "\(key) \(found)" + (target.map { "/\($0)" } ?? "")
          }.joined(separator: ", ")
          let change = prior(candidate)?.score.map { " (Δ \(delta(score.total - $0.total)))" } ?? ""
          let lead = score.answerFirst.map { $0 ? "yes" : "no" } ?? "n/a"
          metrics = """
            <p><strong>\(score.total)/100\(change)</strong><br>
            Shape \(score.shapePoints)/\(score.shapeMaximum) · \(shape.isEmpty ? "no components" : shape)<br>
            Answer first \(lead) · \(score.answerFirstPoints) points<br>
            Markdown \(score.markdownPoints)/15 · \(score.headings) headings · \(score.listItems) list items ·
            \(score.longParagraphs) long paragraphs · \(score.tables) tables<br>
            Length \(score.lengthPoints)/10 · \(score.words)/\(question.expect.maxWords) words ·
            \(score.characters) characters</p>
            """
        }
        let judge =
          candidate.judge.map { judge in
            let change = prior(candidate)?.judge.map { " (Δ \(delta(judge.score - $0.score)))" } ?? ""
            return "<p><strong>Judge \(judge.score)/5\(change)</strong> · \(escape(judge.comment))</p>"
          } ?? ""
        let darkJudge =
          candidate.darkJudge.map { judge in
            let change = prior(candidate)?.darkJudge.map { " (Δ \(delta(judge.score - $0.score)))" } ?? ""
            return "<p><strong>Dark judge \(judge.score)/5\(change)</strong> · \(escape(judge.comment))</p>"
          } ?? ""
        return """
          <td><h3>\(escape(candidate.group))</h3>\(image)\(dark)\(metrics)\(judge)\(darkJudge)\(failures)\(raw)</td>
          """
      }.joined(separator: "\n")
      return """
        <tr><th scope="row">\(escape(question.question))<small>\(escape(question.category))</small>
        <small>\(escape(question.expect.shape))</small></th>\(cells)</tr>
        """
    }.joined(separator: "\n")
    let autoDelta = baseline.isEmpty ? "" : "<th>Auto Δ (paired)</th>"
    let judgeDelta = baseline.isEmpty ? "" : "<th>Judge Δ (paired)</th>"
    return """
      <!doctype html>
      <html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
      <title>Wicket answer eval</title>
      <style>
      :root { color-scheme: light dark; font: 15px/1.5 system-ui, sans-serif; }
      body { margin: clamp(1rem, 4vw, 3rem); }
      table { border-collapse: collapse; }
      th, td { text-align: left; vertical-align: top; padding: .65rem; border-bottom: 1px solid GrayText; }
      th small { display: block; font-weight: normal; margin-top: .4rem; }
      h3 { margin: 0 0 .5rem; }
      p { margin: .5rem 0; }
      .scroll { overflow-x: auto; }
      .answers td { min-width: 18rem; }
      .answers th[scope=row] { min-width: 12rem; max-width: 18rem; }
      img { width: min(100%, 32rem); height: auto; display: block; }
      pre { white-space: pre-wrap; overflow-wrap: anywhere; }
      </style>
      <h1>Wicket answer eval</h1>
      <p>Compare the renders by eye. Automatic and judge scores are supporting signals.</p>
      <h2>Summary</h2>
      <div class="scroll"><table><thead><tr>
      <th>Variant · agent</th><th>Category</th><th>Scored</th><th>Auto /100</th>\(autoDelta)
      <th>Light judge /5</th>\(judgeDelta)</tr></thead><tbody>\(summaries)</tbody></table></div>
      <h2>Answers</h2>
      <div class="scroll"><table class="answers"><thead><tr><th>Question</th>
      \(ordered(results.map(\.group)).map { "<th>\(escape($0))</th>" }.joined())
      </tr></thead><tbody>\(rows)</tbody></table></div>
      </html>
      """
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
