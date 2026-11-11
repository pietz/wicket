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
  /// How well a query matches the best of some names: 2 exact, 1 prefix, 0 otherwise.
  /// Names and query are folded and ignore whitespace. An empty query matches nothing.
  static func tier(_ query: [UInt32], _ names: [String]) -> Int {
    names.map { tier(query, folded: Fold.query($0)) }.max() ?? 0
  }
  /// The same rule for a name that is already folded, such as a `SearchKey`'s `compact`.
  static func tier(_ query: [UInt32], folded name: [UInt32]) -> Int {
    query.isEmpty ? 0 : (name == query ? 2 : (name.starts(with: query) ? 1 : 0))
  }

  /// What a pattern extension did for the current input.
  enum Pattern: Sendable {
    case items([Row])
    /// The run failed: a one-line summary for the error row, which enters the command to show the report.
    case failed(String)
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
  /// 3. Name matches: apps, files, extension commands and the host's rows (Settings, and Clipboard History
  ///    when it is on), by tier, then usage for
  ///    this exact input, then fuzzy score, then kind in that order, then title. Usage never crosses
  ///    a tier.
  /// 4. Ask agent: on top when nothing is strong or the input ends with "?", otherwise right after
  ///    the last prefix or exact match, so it stays above the loose matches.
  /// 5. Fallback extensions, only when nothing is strong, right after Ask agent.
  /// 6. Error and repair rows.
  ///
  /// Strong means a math result, a nonempty successful pattern result or a name match with tier 1
  /// or 2. Empty input lists apps by usage, then Ask agent, and never offers fallbacks.
  ///
  /// - Parameters:
  ///   - math: Rows from the math source.
  ///   - apps: Rows from the app source, already filtered to what matches the input.
  ///   - files: Rows from file search, the best by file name.
  ///   - patterns: Outcomes of the pattern extensions that ran, by extension ID.
  ///   - extensions: Manifests of the enabled, valid extensions.
  ///   - problems: Repair text of the enabled extensions whose manifest is invalid.
  ///   - sources: The enabled source IDs; `clipboard` offers the Clipboard History row.
  static func compose(
    query input: String, math: [Row], apps: [Row], files: [Row], patterns: [String: Pattern],
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
              icon: "exclamationmark.triangle", actions: [.run(Address(id: id, input: input))])))
      }
    }
    let mathRows = math.map { Result(provider: "math", row: $0) }
    if !mathRows.isEmpty { reason = "math result" }

    // Name matches.
    enum Kind: Int { case app, file, command, host }
    struct Candidate { let result: Result, kind: Kind, tier: Int, usage: Double, score: Int }
    func candidate(_ result: Result, _ kind: Kind, names: [String], requireMatch: Bool) -> Candidate? {
      var score = 0
      var tier = 0
      if !query.isEmpty {
        let keys = names.map(SearchKey.init)
        let scores = keys.compactMap { FuzzyMatcher.score(query, words: words, $0) }
        if let best = scores.max() { score = best } else if requireMatch { return nil }
        tier = keys.map { Self.tier(query, folded: $0.compact) }.max() ?? 0
      }
      return Candidate(
        result: result, kind: kind, tier: tier,
        usage: usage.frecency(result.id, query: input, now: now), score: score)
    }
    var candidates = apps.compactMap {
      candidate(
        Result(provider: "apps", row: $0), .app, names: [$0.title] + ($0.keywords ?? []), requireMatch: false)
    }
    candidates += (query.isEmpty ? [] : files).compactMap {
      candidate(Result(provider: "files", row: $0), .file, names: [$0.title], requireMatch: true)
    }
    for id in extensions.keys where !answered.contains(id) {
      let manifest = extensions[id]!
      let row = Row(
        id: "command", title: manifest.name, subtitle: manifest.keyword, icon: manifest.icon,
        actions: [.run(Address(id: id, input: ""))])
      if let found = candidate(
        Result(provider: id, row: row), .command,
        names: [manifest.name] + (manifest.keyword.map { [$0] } ?? []), requireMatch: !query.isEmpty)
      {
        candidates.append(found)
      }
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
      for result in rows {
        if let found = candidate(
          result, .host, names: [result.row.title] + (result.row.keywords ?? []), requireMatch: true)
        {
          candidates.append(found)
        }
      }
    }
    candidates.sort { a, b in
      if a.tier != b.tier { return a.tier > b.tier }
      if query.isEmpty, a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
      if a.usage != b.usage { return a.usage > b.usage }
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
      return Output(
        results: mathRows + patternRows + candidates.map(\.result) + [ask] + failures + repairs,
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
