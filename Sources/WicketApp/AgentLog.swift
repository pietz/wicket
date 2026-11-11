import Foundation

/// A local record of agent runs, for debugging after the fact: per run a header (time, agent, model,
/// effort, mode, command, folder), every JSON line sent and received, stderr, the process exit and
/// how the run ended. Raw protocol lines, on the user's own machine and nowhere else. The file is
/// moved to `agent.old.log` when it is over 2 MiB at the start of a run. Writes happen on a serial
/// queue and every failure is ignored, so the log can never slow down or break a run.
final class AgentLog: Sendable {
  static let limit = 2 * 1024 * 1024
  /// Longest logged line; the rest of a longer one is counted, not kept.
  static let lineLimit = 32 * 1024
  let file: URL
  private let old: URL
  private let queue = DispatchQueue(label: "app.wicket.agent-log", qos: .utility)

  init(folder: URL) {
    file = folder.appending(path: "agent.log")
    old = folder.appending(path: "agent.old.log")
  }

  /// `~/Library/Logs/Wicket` or `~/Library/Logs/Wicket Dev`; inside `WICKET_CONFIG_DIR` when that is
  /// set, so test and headless runs never touch the real one.
  static func standard(
    edition: Edition = .current, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> AgentLog {
    if environment["WICKET_CONFIG_DIR"]?.isEmpty == false {
      return AgentLog(folder: edition.configDirectory(environment: environment))
    }
    return AgentLog(
      folder: FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Logs/\(edition.name)", directoryHint: .isDirectory))
  }

  /// Starts a run: rotates the file if it is too big, then writes the header.
  func begin(_ settings: AgentConfiguration, command: [String], folder: URL) -> Run {
    queue.async { self.rotate() }
    let run = Run(log: self)
    run.note(
      "RUN",
      "agent=\(settings.agent.rawValue) model=\(settings.model ?? "default") "
        + "effort=\(settings.effort ?? "default") mode=\(settings.permissionMode) "
        + "folder=\(folder.path) command=\(command.joined(separator: " "))")
    return run
  }

  /// Runs on the queue.
  private func rotate() {
    let manager = FileManager.default
    try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    guard size > Self.limit else { return }
    try? manager.removeItem(at: old)
    try? manager.moveItem(at: file, to: old)
  }

  /// One run's lines, each tagged with a short run ID because a stopping run can overlap the next.
  final class Run: @unchecked Sendable {
    private let log: AgentLog
    private let id = String(UUID().uuidString.prefix(4)).lowercased()
    /// Only touched on the log's queue.
    private var descriptor: Int32 = -1
    private let clock = DateFormatter()
    private let encoder = JSONEncoder()

    fileprivate init(log: AgentLog) {
      self.log = log
      clock.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func sent(_ value: JSONValue) { json("SEND", value) }
    func received(_ value: JSONValue) { json("RECV", value) }
    func stderr(_ chunk: Data) {
      let now = Date()
      log.queue.async { [self] in
        for line in String(decoding: chunk, as: UTF8.self).split(whereSeparator: \.isNewline) {
          append("ERR", String(line), at: now)
        }
      }
    }
    func note(_ tag: String, _ text: String) {
      let now = Date()
      log.queue.async { [self] in append(tag, text, at: now) }
    }
    func close() {
      log.queue.async { [self] in
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -2
      }
    }

    private func json(_ tag: String, _ value: JSONValue) {
      let now = Date()
      log.queue.async { [self] in
        append(tag, (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?", at: now)
      }
    }
    /// On the queue: opens the file at the first line, so a run that logs nothing creates nothing.
    private func append(_ tag: String, _ text: String, at now: Date) {
      if descriptor == -1 {
        descriptor = open(log.file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
      }
      guard descriptor >= 0 else { return }
      var text = text
      let excess = text.utf8.count - AgentLog.lineLimit
      if excess > 0 { text = String(text.prefix(AgentLog.lineLimit)) + "… [\(excess) more bytes]" }
      let line = "\(clock.string(from: now)) #\(id) \(tag) \(text)\n"
      _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
    }
  }
}
