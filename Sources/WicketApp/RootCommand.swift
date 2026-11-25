import Foundation

typealias AppSearch = @MainActor (String) async -> SearchIndex

/// Root search: the installed apps, Spotlight files, extension items and pattern extensions, ranked into
/// one list for an input (`Ranking.compose`). Sources answer progressively; each search delivers a
/// complete list whenever its sources allow, and nothing from a search that a newer one or `cancel`
/// replaced. The panel and headless `--query` both search through it.
@MainActor final class RootCommand {
  struct Output {
    /// The input the list was composed for.
    let input: String
    let results: [Result]
    let firstProblem: String?
  }
  /// How long the list waits for pattern extensions whose regex matched: a few frames, more than the
  /// bundled calculator's few milliseconds and short enough that a slow pattern never delays typing.
  static let patternHold = Duration.milliseconds(30)

  /// The installed apps, the one source answered in process besides file search.
  private let apps: AppSearch?
  private let files: FilesProvider?
  private let directory: CommandDirectory
  private let store: ConfigurationStore
  private let history: UsageHistory
  private var extensions: ExtensionHost { directory.extensions }

  private var appMatches: [SearchIndex.Match] = []
  /// The previous file rows stay until the first batch for a new input replaces them.
  private var fileRows: [Row] = []
  private var fileMatches: [SearchIndex.Match] = []
  private var itemRows: [Ranking.Names] = []
  private var patterns: [String: Ranking.Pattern] = [:]
  /// The pattern extensions whose regex matched the input; their answers are `patterns`.
  private var matchedPatterns: Set<String> = []
  private var tasks: [Task<Void, Never>] = []
  private var generation = 0
  /// Sources whose results for this input may still arrive: running pattern extensions and file search.
  private(set) var pending: Set<String> = []
  /// From the start of a search to its first list, or until it is cancelled.
  private(set) var isSearching = false
  /// Why the last list has a strong match, or nil when nothing matches strongly.
  private(set) var strongReason: String?

  init(
    apps: AppSearch?, files: FilesProvider?, directory: CommandDirectory, store: ConfigurationStore,
    history: UsageHistory
  ) {
    self.apps = apps
    self.files = files
    self.directory = directory
    self.store = store
    self.history = history
  }

  /// The pattern extensions that matched the input and have not answered yet. What is typed was meant
  /// for them: Ask agent and fallbacks wait for them (`Ranking.compose`), and so may Return
  /// (`Navigator.returnPlan`). The list itself waits only `patternHold`.
  var runningPatterns: Set<String> { matchedPatterns.filter { patterns[$0] == nil } }
  /// Whether `result` is one of the rows a pattern extension answered this input with, rather than, say,
  /// the command row of a pattern that answered nothing.
  func isPatternResult(_ result: Result?) -> Bool {
    guard let result, case .items(let rows) = patterns[result.provider] else { return false }
    return rows.contains(result.row)
  }
  /// Whether a pattern still running would list its rows above `result` (`Ranking.compose`).
  func outranked(_ result: Result?) -> Bool {
    let running = runningPatterns
    guard !running.isEmpty, result?.keywordArgument == nil else { return false }
    guard let result, isPatternResult(result) else { return true }
    let ids = running.union([result.provider])
    let manifests = ids.reduce(into: [String: ExtensionManifest]()) {
      $0[$1] = extensions.commands[$1]?.manifest
    }
    return Ranking.byName(ids, manifests).first != result.provider
  }
  /// Whether a pattern extension that matched the input failed: Return never asks the agent in its place,
  /// though Ask agent shows again, with the failure, for ⌘↩ and a click.
  var failedPattern: Bool {
    matchedPatterns.contains { if case .failed = patterns[$0] { true } else { false } }
  }

  /// Searches for `input`, replacing any search before it. `speaking`: voice is writing the input, so
  /// pattern extensions wait a moment before running. `deliver` gets each list.
  func search(_ input: String, speaking: Bool, deliver: @escaping (Output) -> Void) {
    cancel()
    isSearching = true
    let current = generation
    let request = ProviderRequest(input: input)
    let host = extensions
    let configuration = store.configuration
    appMatches = []
    patterns.removeAll()
    let active = configuration.sources(extensions: extensions.ids).filter(\.enabled)
    let query = SearchQuery(input)
    // Extension items are in memory: matched once per input, not on every batch that recomposes.
    let keyword = KeywordQuery(input)
    itemRows = active.compactMap { extensions.commands[$0.id] }.map { command in
      let exact = keyword.map { keyword in
        { (row: Row) in
          keyword.argument(
            for: row, from: command.id,
            fieldsFor: {
              self.directory.availableFields($0, in: configuration)
            }) != nil
        }
      }
      return Ranking.Names(
        provider: command.id, kind: .item, matches: command.rootItems(query, including: exact))
    }
    // The previous file rows stay until the first batch for this input replaces them, so files do not
    // vanish and return on every keystroke; ranking drops those the new input no longer matches.
    let files = files.flatMap { files in
      active.contains { $0.id == files.id } && FileSearch.predicate(for: input) != nil ? files : nil
    }
    if files == nil { fileRows = [] }
    fileMatches = SearchIndex(fileRows).scored(query, forFile: true)
    let apps = active.contains { $0.id == AppsProvider.id } ? apps : nil
    var appsReady = apps == nil
    let compose = { [weak self] in
      guard let self else { return }
      isSearching = false
      let ranked = rank(query)
      strongReason = ranked.strongReason
      deliver(Output(input: input, results: ranked.results, firstProblem: ranked.firstProblem))
    }
    // The list is delivered once the apps answered and, for up to `patternHold`, the pattern
    // extensions whose regex matched, so a calculation lands with the rest of the list rather than
    // after it, without an Ask agent row first. A slower pattern adds its rows when it finishes.
    // One missing a permission it declares runs nothing here and shows nothing: typing never brings up
    // Wicket's permission row, which shows when the command is entered.
    let matched = Set(
      active.compactMap { extensions.commands[$0.id] }
        .filter { $0.manifest.matches(input) && extensions.permissions.missing($0).isEmpty }.map(\.id))
    matchedPatterns = matched
    var holding = !matched.isEmpty
    let hold = Task { [weak self] in
      guard holding, (try? await Task.sleep(for: Self.patternHold)) != nil, let self, generation == current
      else { return }
      holding = false
      if appsReady { compose() }
    }
    tasks.append(hold)
    if let apps {
      tasks.append(
        Task { [weak self] in
          let index = await apps(input)
          guard let self, !Task.isCancelled, generation == current else { return }
          appMatches = index.scored(query)
          appsReady = true
          if !holding { compose() }
        })
    }
    for entry in active {
      guard matched.contains(entry.id), let command = extensions.commands[entry.id] else { continue }
      pending.insert(entry.id)
      tasks.append(
        Task { [weak self] in
          do {
            if speaking { try await Task.sleep(for: .milliseconds(350)) }
            let view = try await host.view(command, request: request, rootMatch: true)
            guard let self, !Task.isCancelled, generation == current else { return }
            // At the root a pattern result only contributes items; a body is entered like a detail.
            patterns[entry.id] =
              view.pageBody(reservedFields: command.manifest.fields) == nil
              ? .items(view.items)
              : .items([
                Row(
                  id: "detail", title: command.manifest.name, subtitle: "Show details",
                  icon: command.manifest.icon,
                  actions: [.run(Address(id: entry.id, input: request.input, link: true))])
              ])
          } catch {
            guard let self, !Task.isCancelled, generation == current else { return }
            patterns[entry.id] = .failed(
              error.localizedDescription.components(separatedBy: "\n").first ?? "")
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          pending.remove(entry.id)
          if holding, pending.isDisjoint(with: matched) {
            holding = false
            hold.cancel()
          }
          if appsReady, !holding { compose() }
        })
    }
    // Each batch of file results replaces the previous one; cancelling the task stops the query.
    if let files {
      pending.insert(files.id)
      tasks.append(
        Task { [weak self] in
          var received = false
          for await rows in files.batches(for: request.input) {
            guard let self, !Task.isCancelled, generation == current else { return }
            received = true
            fileRows = rows
            fileMatches = SearchIndex(rows).scored(query, forFile: true)
            if appsReady, !holding { compose() }
          }
          guard let self, !Task.isCancelled, generation == current else { return }
          if !received {
            fileRows = []
            fileMatches = []
          }
          pending.remove(files.id)
          if appsReady, !holding { compose() }
        })
    }
    if appsReady, !holding { compose() }
  }

  /// Stops the search: nothing it started is delivered any more.
  func cancel() {
    generation += 1
    for task in tasks { task.cancel() }
    tasks.removeAll()
    isSearching = false
    pending.removeAll()
    matchedPatterns.removeAll()
  }

  /// Waits until the search is done, including a search started while this was waiting.
  func settled() async {
    var seen = generation
    repeat {
      seen = generation
      for task in tasks { await task.value }
    } while seen != generation
  }

  private func rank(_ query: SearchQuery) -> Ranking.Output {
    let configuration = store.configuration
    let enabled = Set(configuration.sources(extensions: extensions.ids).filter(\.enabled).map(\.id))
    let commands = extensions.commands.filter { enabled.contains($0.key) }
    let names =
      [
        Ranking.Names(provider: AppsProvider.id, kind: .app, matches: appMatches),
        Ranking.Names(provider: "files", kind: .file, matches: fileMatches),
      ] + itemRows
    return Ranking.compose(
      query: query, names: names, patterns: patterns, running: runningPatterns,
      extensions: commands.mapValues(\.manifest),
      problems: extensions.problems.filter { enabled.contains($0.key) },
      hosts: directory.rootRows(configuration),
      hostFields: { directory.availableFields($0, in: configuration) },
      usage: history.store, now: Date())
  }
}
