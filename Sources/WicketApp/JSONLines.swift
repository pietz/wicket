import Foundation
import Synchronization

/// The last 4 KiB of stderr, readable at any moment: a descendant may keep stderr from ever ending.
private final class StderrTail: Sendable {
  private let text = Mutex("")
  func add(_ chunk: Data) {
    text.withLock { $0 = String(($0 + String(decoding: chunk, as: UTF8.self)).suffix(4096)) }
  }
  var said: String { text.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A child process that speaks one JSON value per line: framing bounded at 4 MiB as the bytes are read,
/// reads off the cooperative pool, writes in order through ProcessTree, and the tail of stderr kept
/// for errors. The process ending is a failure, even while a descendant keeps its output open.
@MainActor
final class JSONLines {
  var onMessage: (JSONValue) -> Void = { _ in }
  /// Why the process ended or its output broke. Never called after `stop`.
  var onClose: (String) -> Void = { _ in }
  private let tree: ProcessTree
  private var reader: Task<Void, Never>?
  private var exitWatcher: Task<Void, Never>?
  private var closed = false
  private let log: AgentLog.Run?
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return encoder
  }()

  init(
    command: [String], folder: URL, environment: [String: String] = Launch.environment(),
    log: AgentLog.Run? = nil
  ) throws {
    self.log = log
    let started = try Launch.start(
      URL(fileURLWithPath: command[0]), Array(command.dropFirst()), in: folder, environment: environment)
    tree = started.tree
    let tail = StderrTail()
    let errors = Task {
      for await chunk in started.stderr.chunks() {
        tail.add(chunk)
        log?.stderr(chunk)
      }
    }
    // The exit is noticed on its own: a descendant that inherited stdout keeps it from ever
    // reaching EOF. Output the CLI wrote before exiting gets a moment to arrive first.
    exitWatcher = Task { [weak self] in
      let exit = await started.tree.exit.value
      try? await Task.sleep(for: .milliseconds(250))
      guard let self else { return }
      let said = tail.said
      close("\(exit)" + (said.isEmpty ? "." : ": " + said))
    }
    reader = Task { [weak self] in
      var framer = LineFramer()
      for await chunk in started.stdout.chunks(limit: LineFramer.limit, perLine: true) {
        guard let self, !closed else { return }
        do {
          for message in try framer.append(chunk) {
            self.log?.received(message)
            onMessage(message)
          }
        } catch {
          close(error.localizedDescription)
          return
        }
      }
      // The exit can beat the last stderr chunk, but a grandchild may hold the pipe open.
      _ = await errors.value(within: .milliseconds(500))
      let said = tail.said
      let exit = await started.tree.exit.value(within: .milliseconds(500))
      guard let self else { return }
      close((exit.map { "\($0)" } ?? "stopped writing") + (said.isEmpty ? "." : ": " + said))
    }
  }
  /// Writes one value and a newline, after the writes before it.
  func send(_ value: JSONValue) {
    guard !closed, let data = try? encoder.encode(value) else { return }
    log?.sent(value)
    tree.write(data + Data([10]))
  }
  private func close(_ reason: String) {
    guard !closed else { return }
    closed = true
    log?.note("EXIT", reason)
    onClose(reason)
  }
  func stop() async {
    let running = !closed
    closed = true
    tree.closeInput()
    reader?.cancel()
    reader = nil
    exitWatcher?.cancel()
    exitWatcher = nil
    let shutdown = await tree.stop(after: .milliseconds(100), grace: .milliseconds(500)).value
    if running {
      switch shutdown {
      case .exited(let exit): log?.note("EXIT", "\(exit)")
      case .notRunning: log?.note("EXIT", "not running")
      case .terminated: log?.note("EXIT", "stopped with SIGTERM")
      case .killed: log?.note("EXIT", "stopped with SIGKILL")
      }
    }
  }
}
