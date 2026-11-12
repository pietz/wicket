import Foundation

/// One row of the launcher list and the source that produced it.
struct Result: Identifiable, Sendable {
  let provider: String
  let row: Row
  var id: String {
    provider.hasPrefix("extension:") ? "\(provider.utf8.count):" + provider + row.id : provider + ":" + row.id
  }
}

/// How the launcher orders what its sources produced. Pure: nothing here reads configuration,
/// the filesystem or a clock, so one function can serve the panel, the headless mode and tests.
enum Ranking {
  /// How well a query matches the best of some names: 2 exact, 1 a prefix of the name from the start
  /// of any of its words ("pass" in "Proton Pass" or "1Password"), 0 otherwise. Names and query are
  /// folded and ignore whitespace. An empty query matches nothing.
  static func tier(_ query: [UInt32], _ names: [String]) -> Int {
    names.map { tier(query, SearchKey($0)) }.max() ?? 0
  }
  /// The same rule for a prepared name. Words start where the fuzzy matcher's do (`SearchKey.boundary`).
  static func tier(_ query: [UInt32], _ key: SearchKey) -> Int {
    if query.isEmpty { return 0 }
    if key.compact == query { return 2 }
    var offset = 0  // where key.scalars[index] is in key.compact
    for (index, scalar) in key.scalars.enumerated() {
      if Unicode.Scalar(scalar)?.properties.isWhitespace ?? false { continue }
      if key.boundary[index] > 0, key.compact[offset...].starts(with: query) { return 1 }
      offset += 1
    }
    return 0
  }

  /// What a pattern extension did for the current input.
  enum Pattern: Sendable {
    case items([Row])
    /// The run failed: a one-line summary for the error row, which enters the command to show the report.
    case failed(String)
  }

  /// The most apps the empty input lists: a short list of the most used, not every installed app.
  static let emptyApps = 20

  /// What a name match is, which breaks ties in this order. Files come last: within a tier and with
  /// equal usage, a file never outranks any other kind, since its name says less about intent.
  enum Kind: Int, Sendable { case app, command, item, host, file }

  /// One source of name matches (apps, files, an extension's items): its rows, already filtered to
  /// what matches the input.
  struct Names: Sendable {
    let provider: String
    let kind: Kind
    let rows: [Row]
  }

  struct Output: Sendable {
    let results: [Result]
    /// Why a strong match exists, or nil when nothing matches strongly.
    let strongReason: String?
  }

  /// The order inside one extension: exact or prefix title and alias, then the order the extension
  /// returned. Pattern results at the root also pass the usage learned for this exact input, which
  /// goes between the two. Rows inside a chosen command pass none.
  static func order(
    _ rows: [Row], provider: String, query input: String, usage: UsageStore = UsageStore(), now: Date = Date()
  ) -> [Result] {
    let query = Fold.query(input)
    return rows.enumerated().map { offset, row -> (Result, Int, Double, Int) in
      let result = Result(provider: provider, row: row)
      return (
        result, tier(query, [row.title] + (row.keywords ?? [])),
        usage.frecency(result.id, query: input, now: now), offset
      )
    }.sorted { a, b in
      if a.1 != b.1 { return a.1 > b.1 }
      return a.2 == b.2 ? a.3 < b.3 : a.2 > b.2
    }.map(\.0)
  }

  /// The whole list at the root of the launcher, best first:
  ///
  /// 1. A math result.
  /// 2. Pattern extension results, one extension after another by name, each in its own order.
  /// 3. Name matches: apps, extension commands, extension items, the host's rows (Settings, and
  ///    Clipboard History when it is on) and files, by tier, then usage for this exact input, then
  ///    files after every other kind, then fuzzy score, then kind in that order, then title. Usage
  ///    never crosses a tier.
  /// 4. Ask agent: on top when nothing is strong or the input ends with "?", otherwise right after
  ///    the last word-prefix or exact match, so it stays above the loose matches.
  /// 5. Fallback extensions, only when nothing is strong, right after Ask agent.
  /// 6. Error and repair rows.
  ///
  /// Strong means a math result, a nonempty successful pattern result or a name match with tier 1
  /// or 2. Empty input lists at most `emptyApps` apps, by their use under any input and then by name,
  /// then extension commands and Ask agent, and never offers fallbacks.
  ///
  /// - Parameters:
  ///   - math: Rows from the math source.
  ///   - names: Name matches from apps, file search and extension items. Only apps list anything
  ///     for empty input.
  ///   - patterns: Outcomes of the pattern extensions that ran, by extension ID.
  ///   - extensions: Manifests of the enabled, valid extensions.
  ///   - problems: Repair text of the enabled extensions whose manifest is invalid.
  ///   - sources: The enabled source IDs; `clipboard` offers the Clipboard History row.
  static func compose(
    query input: String, math: [Row], names: [Names], patterns: [String: Pattern],
    extensions: [String: ExtensionManifest], problems: [String: String], sources: Set<String> = [],
    usage: UsageStore, now: Date = Date()
  ) -> Output {
    let query = Fold.query(input)
    let words = Fold.words(input)
    func named(_ ids: some Sequence<String>) -> [String] {
      ids.sorted {
        let order = (extensions[$0]?.name ?? $0).localizedStandardCompare(extensions[$1]?.name ?? $1)
        return order == .orderedSame ? $0 < $1 : order == .orderedAscending
      }
    }
    func icon(_ id: String) -> String? { extensions[id]?.icon }

    // Pattern results and failures.
    var patternRows: [Result] = []
    var failures: [Result] = []
    var answered: Set<String> = []
    var reason: String?
    for id in named(patterns.keys.filter { extensions[$0] != nil }) {
      switch patterns[id]! {
      case .items(let items):
        if !items.isEmpty { answered.insert(id) }
        if !items.isEmpty, reason == nil { reason = "pattern result: " + id }
        patternRows += order(items, provider: id, query: input, usage: usage, now: now)
      case .failed(let summary):
        answered.insert(id)
        failures.append(
          Result(
            provider: id,
            row: Row(
              id: "error", title: extensions[id]!.name + " failed", subtitle: summary,
              icon: "exclamationmark.triangle", actions: [.run(Address(id: id, input: input, link: true))])))
      }
    }
    let mathRows = math.map { Result(provider: "math", row: $0) }
    if !mathRows.isEmpty { reason = "math result" }

    // Name matches. Every row matches by its title and keywords; empty input matches everything given.
    struct Candidate { let result: Result, kind: Kind, tier: Int, usage: Double, score: Int }
    let totals = query.isEmpty ? usage.totals(now: now) : [:]
    func candidate(_ result: Result, _ kind: Kind) -> Candidate? {
      var score = 0
      var tier = 0
      if !query.isEmpty {
        let keys = ([result.row.title] + (result.row.keywords ?? [])).map(SearchKey.init)
        guard let best = keys.compactMap({ FuzzyMatcher.score(query, words: words, $0) }).max() else {
          return nil
        }
        score = best
        tier = keys.map { Self.tier(query, $0) }.max() ?? 0
      }
      return Candidate(
        result: result, kind: kind, tier: tier,
        usage: query.isEmpty ? totals[result.id] ?? 0 : usage.frecency(result.id, query: input, now: now),
        score: score)
    }
    var candidates = names.flatMap { source in
      source.rows.compactMap { candidate(Result(provider: source.provider, row: $0), source.kind) }
    }
    for id in extensions.keys where !answered.contains(id) {
      let manifest = extensions[id]!
      let row = Row(
        id: "command", title: manifest.name, subtitle: manifest.keyword, icon: manifest.icon,
        actions: [.run(Address(id: id, input: ""))], keywords: manifest.keyword.map { [$0] })
      if let found = candidate(Result(provider: id, row: row), .command) { candidates.append(found) }
    }
    if !query.isEmpty {
      var rows = [
        Result(
          provider: "settings",
          row: Row(
            id: "open", title: "Settings", icon: "gearshape",
            actions: [.run(Address(extensionName: "settings"))], keywords: ["preferences"]))
      ]
      if sources.contains("clipboard") {
        rows.append(
          Result(
            provider: "clipboard",
            row: Row(
              id: "open", title: ClipboardHistory.title, icon: "doc.on.clipboard",
              actions: [.run(Address(extensionName: "clipboard"))], keywords: ["pasteboard"])))
      }
      candidates += rows.compactMap { candidate($0, .host) }
    }
    candidates.sort { a, b in
      if a.tier != b.tier { return a.tier > b.tier }
      if query.isEmpty, a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
      if a.usage != b.usage { return a.usage > b.usage }
      if (a.kind == .file) != (b.kind == .file) { return b.kind == .file }
      if a.score != b.score { return a.score > b.score }
      if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
      let order = a.result.row.title.localizedStandardCompare(b.result.row.title)
      return order == .orderedSame ? a.result.id < b.result.id : order == .orderedAscending
    }
    if reason == nil, let first = candidates.first, first.tier >= 1 {
      reason = "title prefix: " + first.result.id
    }

    let ask = Result(
      provider: "agent",
      row: Row(id: "ask", title: "Ask agent", subtitle: "⌘↩", icon: "sparkles", actions: [.send(input)]))
    let repairs = problems.keys.sorted().map {
      Result(
        provider: $0,
        row: Row(
          id: "discovery-error", title: $0 + " needs repair", subtitle: "Invalid extension manifest",
          icon: "exclamationmark.triangle",
          actions: [
            .agent("Fix this extension. " + problems[$0]!.split(separator: "\n").joined(separator: ": "))
          ]))
    }
    if query.isEmpty {
      let apps = candidates.filter { $0.kind == .app }.prefix(emptyApps)
      let rest = candidates.filter { $0.kind != .app }
      return Output(
        results: mathRows + patternRows + (apps + rest).map(\.result) + [ask] + failures + repairs,
        strongReason: "empty input lists apps first")
    }

    // Fallbacks replace their extension's own command row when nothing is strong.
    var fallbacks: [Result] = []
    if reason == nil {
      let ids = named(extensions.filter { $0.value.fallback }.keys)
      candidates.removeAll { $0.kind == .command && ids.contains($0.result.provider) }
      fallbacks = ids.map {
        Result(
          provider: $0,
          row: Row(
            id: "fallback", title: extensions[$0]!.name, subtitle: input, icon: icon($0),
            actions: [.run(Address(id: $0, input: input))]))
      }
    }
    let strong = candidates.filter { $0.tier >= 1 }.map(\.result)
    let loose = candidates.filter { $0.tier == 0 }.map(\.result)
    let head = mathRows + patternRows + strong
    let asksQuestion = input.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    let ordered =
      reason == nil || asksQuestion
      ? [ask] + head + fallbacks + loose
      : head + [ask] + loose
    return Output(results: ordered + failures + repairs, strongReason: reason)
  }
}
