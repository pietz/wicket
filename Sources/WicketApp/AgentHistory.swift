import Foundation
import Observation
import os

/// Past agent runs, newest first, kept in `agent-history.json` in the private folder beside the clipboard
/// history, out of the agent's reach. A run is saved whenever one of its turns ends, with its questions
/// and answers only: no tool output and no `<context>` block. Return on a row reopens the run as it was
/// left, and a follow-up resumes the CLI's own session. Never logs what was asked. Wicket keeps its own
/// copy rather than reading the CLIs' session stores: their formats are undocumented, change with CLI
/// versions and are full of tool noise.
@MainActor @Observable
final class AgentHistory: HostCommand {
  let id = "history"
  struct Run: Codable, Equatable, Sendable {
    struct Turn: Codable, Equatable, Sendable {
      let question: String
      let answer: String
    }
    let id: String
    let agent: AgentConfiguration.Agent
    /// The CLI's session or thread, which a follow-up resumes; nil if the CLI never reported one.
    let session: String?
    let used: Date
    /// The command the first question was asked from, as its header says ("from Weather").
    let source: String?
    /// What the conversation held, oldest first: the earlier turns it keeps, then the last one.
    let turns: [Turn]
  }
  nonisolated static let title = "Agent History"
  nonisolated static let row = Ranking.host("history", title, icon: "clock.arrow.circlepath")
  /// Retention: the newest this many, for this long. Claude Code deletes its own sessions after 30 days
  /// by default, so every run listed can resume.
  nonisolated static let maxEntries = 100
  nonisolated static let maxDays = 30

  private(set) var runs: [Run]
  private let url: URL
  private let writer: LatestWriter<[Run]>
  nonisolated private static let log = Logger(subsystem: "app.wicket", category: "history")

  init(url: URL, now: Date = Date()) {
    self.url = url
    runs = PrivateList.read(url) ?? []
    writer = PrivateList.writer(url, log: Self.log)
    expire(now: now)
  }

  func run(_ id: String) -> Run? { runs.first { $0.id == id } }

  /// Puts the run on top, replacing what was kept of it.
  func save(_ run: Run, now: Date = Date()) {
    let started = ContinuousClock.now
    runs.removeAll { $0.id == run.id }
    runs.insert(run, at: 0)
    expire(now: now)
    writer.submit(runs)
    Self.log.debug(
      "history: \(self.runs.count, privacy: .public) runs, saved in \(ContinuousClock.now - started, privacy: .public)"
    )
  }

  func delete(_ id: String) {
    runs.removeAll { $0.id == id }
    writer.submit(runs)
  }

  /// Whether Clear History has anything to erase: runs, or a list moved aside as unreadable.
  var canClear: Bool { !runs.isEmpty || PrivateList.hasUnreadable(url) }

  func clear() {
    runs.removeAll()
    writer.submit(runs)
    PrivateList.removeUnreadable(url)
  }

  /// Drops what is over `maxEntries` or older than `maxDays`: at launch, whenever the panel opens and
  /// before the list is shown.
  func expire(now: Date = Date()) {
    guard
      let kept = PrivateList.retained(
        runs, count: Self.maxEntries, days: Self.maxDays, date: \.used, now: now)
    else { return }
    runs = kept
    writer.submit(runs)
  }

  /// The command behind the reserved address `history`, answered like an extension's: the input
  /// filters, and a submitted `{"delete": id}` deletes that run first. A submitted `{"open": id}` reopens
  /// the run as a conversation instead (`reopened`).
  func view(for request: ProviderRequest) -> ProviderView {
    if request.submitted, let id = request.arguments["delete"] { delete(id) }
    return ProviderView(items: rows(matching: request.input))
  }
  /// Available whatever sources are on.
  nonisolated static func isAvailable(in configuration: Configuration, extensions: [String]) -> Bool { true }
  func reopened(_ arguments: [String: String]) -> Run? { arguments["open"].flatMap(run) }

  /// Newest first, each word of the input somewhere in the run's questions or answers, ignoring case
  /// and diacritics. The title is the first question, the subtitle its age and agent.
  func rows(matching input: String, now: Date = Date()) -> [Row] {
    expire(now: now)
    let words = input.split(whereSeparator: \.isWhitespace).map(String.init)
    let ages = RelativeDateTimeFormatter()
    ages.unitsStyle = .abbreviated
    ages.dateTimeStyle = .named
    let matches = runs.filter { run in
      words.allSatisfy { word in
        run.turns.contains {
          $0.question.localizedStandardContains(word) || $0.answer.localizedStandardContains(word)
        }
      }
    }
    return matches.map { run in
      let title = (run.turns.first?.question ?? "").prefix(300).split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      return Row(
        id: run.id, title: title,
        subtitle: "\(ages.localizedString(for: run.used, relativeTo: now)) · \(run.agent.title)",
        icon: "clock.arrow.circlepath",
        actions: [
          .run(Address(arguments: ["open": run.id]), title: "Reopen"),
          .run(Address(arguments: ["delete": run.id]), title: "Delete"),
        ])
    }
  }

  func finish() async { await writer.finish() }
}
