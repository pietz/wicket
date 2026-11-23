import Foundation

/// One row of the launcher list and the source that produced it.
struct Result: Identifiable, Sendable, Equatable {
  enum RootExtensionRow: Sendable { case command, item }

  let provider: String
  let row: Row
  let rootExtensionRow: RootExtensionRow?
  let keywordArgument: KeywordQuery.Argument?
  var id: String {
    provider.hasPrefix("extension:") ? "\(provider.utf8.count):" + provider + row.id : provider + ":" + row.id
  }

  init(
    provider: String, row: Row, rootExtensionRow: RootExtensionRow? = nil,
    keywordArgument: KeywordQuery.Argument? = nil
  ) {
    self.provider = provider
    self.row = row
    self.rootExtensionRow = rootExtensionRow
    self.keywordArgument = keywordArgument
  }
}

/// The literal keyword and space belong to search. The rest is passed through as field text.
struct KeywordQuery {
  struct Argument: Sendable, Equatable {
    let field: String
    let text: String
    let keywordLength: Int
  }

  private let input: String
  private let lastText: String.Index

  init?(_ input: String) {
    guard let space = input.firstIndex(of: " "), let last = input.lastIndex(where: { !$0.isWhitespace }),
      space < last
    else { return nil }
    self.input = input
    lastText = last
  }

  func argument(for row: Row, from provider: String, fieldsFor: (String) -> [ExtensionManifest.Field])
    -> Argument?
  {
    guard
      let start = row.keywords?.compactMap({ keyword -> String.Index? in
        guard !keyword.isEmpty,
          let end = input.range(of: keyword + " ", options: [.anchored, .caseInsensitive])?.upperBound,
          end <= lastText
        else { return nil }
        return end
      }).max(),
      let field = row.editableRootFields(from: provider, fieldsFor: fieldsFor).first(where: {
        $0.type == .text
      })
    else { return nil }
    return Argument(
      field: field.name, text: String(input[start...]), keywordLength: start.utf16Offset(in: input) - 1)
  }
}

extension Row {
  func editableRootFields(from provider: String, fieldsFor: (String) -> [ExtensionManifest.Field])
    -> [ExtensionManifest.Field]
  {
    guard case .run(let address)? = actions.first?.kind, !address.link,
      let target = address.extensionName == nil ? provider : address.targetID
    else { return [] }
    return fieldsFor(target).filter { $0.inSearchBar && address.fields?[$0.name] == nil }
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
  /// A file passes `words: false` and is a prefix match only from the start of its name: file search
  /// returns every file with a word starting like the input, and they must not all be strong.
  static func tier(_ query: [UInt32], _ key: SearchKey, words: Bool = true) -> Int {
    if query.isEmpty { return 0 }
    if key.compact == query { return 2 }
    if !words { return key.compact.starts(with: query) ? 1 : 0 }
    var offset = 0  // where key.scalars[index] is in key.compact
    for (index, scalar) in key.scalars.enumerated() {
      if Unicode.Scalar(scalar)?.properties.isWhitespace ?? false { continue }
      if key.boundary[index] > 0, key.compact[offset...].starts(with: query) { return 1 }
      offset += 1
    }
    return 0
  }

  /// A host's row at the root, which opens `id`: Settings or a host command.
  static func host(_ id: String, _ title: String, icon: String, keywords: [String]? = nil) -> Result {
    Result(
      provider: id,
      row: Row(
        id: "open", title: title, icon: icon, actions: [.run(Address(extensionName: id))], keywords: keywords)
    )
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
    let hasProblems: Bool
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

  /// Extension IDs in the order their pattern results and fallbacks are listed: by name, then ID.
  static func byName(_ ids: some Sequence<String>, _ extensions: [String: ExtensionManifest]) -> [String] {
    ids.sorted {
      let order = (extensions[$0]?.name ?? $0).localizedStandardCompare(extensions[$1]?.name ?? $1)
      return order == .orderedSame ? $0 < $1 : order == .orderedAscending
    }
  }

  /// The whole list at the root of the launcher, best first:
  ///
  /// 1. Exact keywords with text for an editable field, longest keyword first, then the name matches' tie-breaks.
  /// 2. Pattern extension results, one extension after another by name, each in its own order.
  /// 3. Name matches: apps, extension commands, extension items, the host's rows (Settings, Agent
  ///    History, and Clipboard History when it is on: `hosts`) and files, by tier, then usage for this exact input, then
  ///    files after every other kind, then fuzzy score, then kind in that order, then title. Usage
  ///    never crosses a tier.
  /// 4. Ask agent, on top when nothing is strong and below the results for a keyword with text.
  /// 5. Fallback extensions, only when nothing is strong, right after Ask agent.
  ///
  /// Without a keyword argument, Ask agent and fallbacks wait while a matched pattern extension is
  /// running (`running`). Once it answers nothing or fails they show.
  /// 6. Error and repair rows.
  ///
  /// Strong means a nonempty successful pattern result or a name match with a positive tier.
  /// Empty input lists at most `emptyApps` apps, by their use under any input and then by name,
  /// then extension commands, and never offers Ask agent or fallbacks.
  ///
  /// - Parameters:
  ///   - names: Name matches from apps, file search and extension items. Only apps list anything
  ///     for empty input.
  ///   - patterns: Outcomes of the pattern extensions that ran, by extension ID.
  ///   - running: The pattern extensions that matched the input and have not answered yet.
  ///   - extensions: Manifests of the enabled, valid extensions.
  ///   - problems: Repair text of the enabled extensions with an invalid manifest or user.json.
  ///   - hosts: The host's own rows (`CommandDirectory.rootRows`), listed for a nonempty input only.
  ///   - hostFields: The fields of an available host command, which a host row or extension item may target.
  static func compose(
    query input: String, names: [Names], patterns: [String: Pattern], running: Set<String> = [],
    extensions: [String: ExtensionManifest], problems: [String: String], hosts: [Result] = [],
    hostFields: (String) -> [ExtensionManifest.Field] = { _ in [] },
    usage: UsageStore, now: Date = Date()
  ) -> Output {
    let query = Fold.query(input)
    let words = Fold.words(input)
    let keyword = KeywordQuery(input)
    func named(_ ids: some Sequence<String>) -> [String] { byName(ids, extensions) }

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

    // Name matches. Every row matches by its title and keywords; empty input matches everything given.
    struct Candidate { let result: Result, kind: Kind, tier: Int, usage: Double, score: Int }
    let totals = query.isEmpty ? usage.totals(now: now) : [:]
    func candidate(_ result: Result, _ kind: Kind, onlyKeyword: Bool = false) -> Candidate? {
      if kind == .host || result.rootExtensionRow != nil,
        case .run(var address)? = result.row.actions.first?.kind,
        let argument = keyword?.argument(
          for: result.row, from: result.provider,
          fieldsFor: {
            extensions[$0]?.fields ?? hostFields($0)
          })
      {
        var row = result.row
        if kind == .item, let subtitle = row.subtitle, !subtitle.isEmpty {
          row.subtitle = subtitle + " · " + argument.text
        } else {
          row.subtitle = argument.text
        }
        address.fields = (address.fields ?? [:]).merging([argument.field: argument.text]) { fixed, _ in fixed
        }
        row.actions[0].kind = .run(address)
        let match = Result(
          provider: result.provider, row: row, rootExtensionRow: result.rootExtensionRow,
          keywordArgument: argument)
        return Candidate(
          result: match, kind: kind, tier: 3, usage: usage.frecency(result.id, query: input, now: now),
          score: 0)
      }
      if onlyKeyword { return nil }
      var score = 0
      var tier = 0
      if !query.isEmpty {
        let keys = ([result.row.title] + (result.row.keywords ?? [])).map(SearchKey.init)
        guard let best = keys.compactMap({ FuzzyMatcher.score(query, words: words, $0) }).max() else {
          return nil
        }
        score = best
        tier = keys.map { Self.tier(query, $0, words: kind != .file) }.max() ?? 0
      }
      return Candidate(
        result: result, kind: kind, tier: tier,
        usage: query.isEmpty ? totals[result.id] ?? 0 : usage.frecency(result.id, query: input, now: now),
        score: score)
    }
    var candidates = names.flatMap { source in
      source.rows.compactMap {
        candidate(
          Result(provider: source.provider, row: $0, rootExtensionRow: source.kind == .item ? .item : nil),
          source.kind)
      }
    }
    for id in extensions.keys where keyword != nil || !answered.contains(id) {
      let manifest = extensions[id]!
      let row = Row(
        id: "command", title: manifest.name, subtitle: manifest.keyword, icon: manifest.icon,
        actions: [.run(Address(id: id, input: "", hidden: manifest.hidden))],
        keywords: manifest.keyword.map { [$0] })
      if let found = candidate(
        Result(provider: id, row: row, rootExtensionRow: .command), .command,
        onlyKeyword: answered.contains(id))
      {
        candidates.append(found)
      }
    }
    if !query.isEmpty { candidates += hosts.compactMap { candidate($0, .host) } }
    candidates.sort { a, b in
      if a.tier != b.tier { return a.tier > b.tier }
      if let a = a.result.keywordArgument, let b = b.result.keywordArgument,
        a.keywordLength != b.keywordLength
      {
        return a.keywordLength > b.keywordLength
      }
      if query.isEmpty, a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
      if a.usage != b.usage { return a.usage > b.usage }
      if (a.kind == .file) != (b.kind == .file) { return b.kind == .file }
      if a.score != b.score { return a.score > b.score }
      if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
      let order = a.result.row.title.localizedStandardCompare(b.result.row.title)
      return order == .orderedSame ? a.result.id < b.result.id : order == .orderedAscending
    }
    let keywordRows = candidates.prefix { $0.result.keywordArgument != nil }
    if let first = keywordRows.first {
      reason = "keyword with argument: " + first.result.id
    } else if reason == nil, let first = candidates.first, first.tier >= 1 {
      reason = "title prefix: " + first.result.id
    }

    let ask = Result(
      provider: "agent",
      row: Row(id: "ask", title: "Ask agent", subtitle: "⌘↩", icon: "sparkles", actions: [.send(input)]))
    let repairs = problems.keys.sorted().map { id in
      let problem = problems[id]!
      // A manifest for a newer contract is not broken: updating Wicket is the fix, in Settings.
      if extensions[id] == nil, problem.contains(ExtensionManifest.ContractError.newerPhrase) {
        return Result(
          provider: id,
          row: Row(
            id: "discovery-error", title: id + " " + ExtensionManifest.ContractError.newerPhrase,
            subtitle: "Written for a newer extension contract", icon: "arrow.down.circle",
            actions: [.run(Address(extensionName: "settings"), title: "Open Settings")]))
      }
      let repair =
        if extensions[id] != nil {
          "Invalid user.json"
        } else if problem.contains(ExtensionManifest.ContractError.olderProgramPhrase) {
          "Update the manifest and program to contract 2"
        } else {
          "Invalid extension manifest"
        }
      return Result(
        provider: id,
        row: Row(
          id: "discovery-error", title: id + " needs repair", subtitle: repair,
          icon: "exclamationmark.triangle",
          actions: [.agent("Fix this extension. " + problem.split(separator: "\n").joined(separator: ": "))]))
    }
    let hasProblems = !failures.isEmpty || !repairs.isEmpty
    if query.isEmpty {
      let apps = candidates.filter { $0.kind == .app }.prefix(emptyApps)
      let rest = candidates.filter { $0.kind != .app }
      return Output(
        results: patternRows + (apps + rest).map(\.result) + failures + repairs,
        strongReason: "empty input lists apps first", hasProblems: hasProblems)
    }
    if !keywordRows.isEmpty {
      let matches = keywordRows.map(\.result)
      let ids = Set(matches.map(\.id))
      let ordered =
        matches + patternRows.filter { !ids.contains($0.id) }
        + candidates.dropFirst(matches.count).map(\.result)
      return Output(
        results: ordered + [ask] + failures + repairs, strongReason: reason, hasProblems: hasProblems)
    }

    // Fallbacks replace their extension's own command row when nothing is strong.
    var fallbacks: [Result] = []
    let fallsBack = reason == nil && running.isEmpty
    if fallsBack {
      let ids = named(extensions.filter { $0.value.fallback }.keys)
      candidates.removeAll { $0.kind == .command && ids.contains($0.result.provider) }
      fallbacks = ids.map {
        Result(
          provider: $0,
          row: Row(
            id: "fallback", title: extensions[$0]!.name, subtitle: input, icon: extensions[$0]!.icon,
            actions: [.run(Address(id: $0, input: input, hidden: extensions[$0]!.hidden))]))
      }
    }
    // Sorted by tier, so the strong come first; with none strong there are no pattern rows either.
    let ordered = (fallsBack ? [ask] + fallbacks : patternRows) + candidates.map(\.result)
    return Output(results: ordered + failures + repairs, strongReason: reason, hasProblems: hasProblems)
  }
}
