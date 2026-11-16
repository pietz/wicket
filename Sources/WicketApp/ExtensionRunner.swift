import Foundation
import Synchronization

/// The last 4 KiB of stderr, counting every byte so a flood stops the process at once.
private final class StderrTail: Sendable {
  private let state = Mutex((tail: Data(), count: 0))
  let limit: Int
  init(limit: Int) { self.limit = limit }
  func read(_ handle: FileHandle, overflow: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    Task {
      for await chunk in handle.chunks(limit: limit, exceeded: overflow) {
        state.withLock { $0 = (Data(($0.tail + chunk).suffix(4096)), $0.count + chunk.count) }
      }
    }
  }
  var text: String { String(decoding: state.withLock { $0.tail }, as: UTF8.self) }
  var exceeded: Bool { state.withLock { $0.count > limit } }
}

/// Stdout read as views over time. Output that starts with `{` is JSON: each complete line that decodes
/// as a view is the newest view as soon as it arrives. What is left at the end is read as the whole
/// output always was: a lone view (pretty-printed too) or Markdown, or after line views nothing or one
/// more view. At most `limit` bytes since the last view, so the bound is per view.
private final class ViewLines: Sendable {
  private struct State {
    var pending: [UInt8] = []
    /// Where the next line to try starts in `pending`.
    var scanned = 0
    var views = 0
    var newest: (view: ProviderView, at: ContinuousClock.Instant)?
    var exceeded = false
  }
  private let state = Mutex(State())
  let limit: Int
  init(limit: Int) { self.limit = limit }
  /// Whether the chunk completed a view.
  func append(_ chunk: Data) -> Bool {
    state.withLock { state in
      guard !state.exceeded else { return false }
      state.pending += chunk
      guard state.pending.count <= limit else {
        state.exceeded = true
        state.pending = []
        return false
      }
      guard state.pending.first(where: { $0 > 32 }) == UInt8(ascii: "{") else { return false }
      let before = state.views
      while let newline = state.pending[state.scanned...].firstIndex(of: 10) {
        let line = state.pending[state.scanned..<newline].drop { $0 <= 32 }
        state.scanned = newline + 1
        guard line.first == UInt8(ascii: "{"), line.last(where: { $0 > 32 }) == UInt8(ascii: "}"),
          let view = try? JSONDecoder().decode(ProviderView.self, from: Data(line))
        else { continue }
        state.newest = (view, .now)
        state.views += 1
        state.pending.removeFirst(state.scanned)
        state.scanned = 0
      }
      return state.views > before
    }
  }
  var exceeded: Bool { state.withLock { $0.exceeded } }
  /// The newest view not handed over yet, once it is `age` old.
  func take(_ age: Duration) -> ProviderView? {
    state.withLock { state in
      guard let newest = state.newest, newest.at + age <= .now else { return nil }
      state.newest = nil
      return newest.view
    }
  }
  /// The last view: what the rest of the output makes, else the newest line view, or nil when the last
  /// line view was handed over already.
  func finish() throws -> ProviderView? {
    let (bytes, views, newest) = state.withLock { ($0.pending, $0.views, $0.newest) }
    let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty, views > 0 { return newest?.view }
    guard !text.isEmpty else { throw ExtensionFailure("Extension printed nothing") }
    // A view is JSON, which starts with `{`, and a broken one stays an error. Anything else is Markdown.
    guard views > 0 || text.hasPrefix("{") else { return ProviderView(body: text) }
    return try JSONDecoder().decode(ProviderView.self, from: Data(bytes))
  }
}

struct ExtensionRunner: Sendable {
  /// For the first view; after it the process runs until it exits or is stopped.
  var deadline: Duration = .seconds(10)
  /// Per view: the bytes since the last one.
  var outputLimit = 1_048_576
  var stderrLimit = 262_144

  /// Runs the program for one request and hands over the views it prints as it prints them, saying
  /// whether it still runs. A view comes over while the process runs only once it is 50 ms old (the
  /// newest one, when several came meanwhile), so a lone view still arrives with the exit, as the last.
  /// Returns after the last view once the process exited successfully, and throws its failure
  /// otherwise; cancelling stops the process.
  func run(
    _ command: ExtensionCommand, request: ProviderRequest,
    view: @escaping @Sendable (_ view: ProviderView, _ running: Bool) -> Void
  ) async throws {
    try Task.checkCancellation()
    // The host answers a command without a program itself and never runs it.
    guard let argv = command.manifest.command else { throw ExtensionFailure("No command to run") }
    var environment = Launch.environment()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    let executable: URL
    if argv[0].contains("/") {
      executable =
        argv[0].hasPrefix("/") ? URL(fileURLWithPath: argv[0]) : command.folder.appending(path: argv[0])
      // Process reports a file without its execute bit as missing, which sends a repair the wrong way.
      if FileManager.default.fileExists(atPath: executable.path),
        !FileManager.default.isExecutableFile(atPath: executable.path)
      {
        throw ExtensionFailure("\(argv[0]) isn't executable: run chmod +x \(argv[0]) in its folder")
      }
    } else {
      guard let found = Launch.which(argv[0], in: environment) else {
        throw ExtensionFailure("Executable not found: \(argv[0])")
      }
      executable = found
    }
    let started = try Launch.start(
      executable, Array(argv.dropFirst()), in: command.folder, environment: environment)
    let tree = started.tree
    let out = ViewLines(limit: outputLimit)
    let err = StderrTail(limit: stderrLimit)
    let stop: @Sendable () -> Void = { _ = tree.stop(after: .zero, grace: .milliseconds(100)) }
    // The first view or the exit, whichever comes first, ends the deadline.
    let (arrived, arrival) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let stdout = Task {
      for await chunk in started.stdout.chunks() {
        if out.append(chunk) { arrival.yield() }
        if out.exceeded {
          stop()
          break
        }
      }
    }
    let stderr = err.read(started.stderr, overflow: stop)
    tree.write(try JSONEncoder().encode(request) + Data([10]))
    tree.closeInput()
    return try await withTaskCancellationHandler {
      let exited = Task {
        _ = await tree.exit.value
        arrival.yield()
      }
      let first = Task { for await _ in arrived { return } }
      let inTime = await first.value(within: deadline) != nil
      exited.cancel()
      // Then the process runs until it exits or is stopped, and its newest view comes over as it ages.
      while inTime, await tree.exit.value(within: .milliseconds(25)) == nil, !Task.isCancelled {
        if let shown = out.take(.milliseconds(50)) { view(shown, true) }
      }
      let exit = inTime ? await tree.exit.value : nil
      _ = await tree.stop(after: .zero, grace: .milliseconds(100)).value
      await stdout.value
      await stderr.value
      try Task.checkCancellation()
      let diagnostic = err.text
      func failure(_ message: String) -> ExtensionFailure {
        ExtensionFailure(message + (diagnostic.isEmpty ? "" : "\n\nStderr (last 4 KiB):\n" + diagnostic))
      }
      if out.exceeded { throw failure("Extension stdout exceeded \(outputLimit) bytes") }
      if err.exceeded { throw failure("Extension stderr exceeded \(stderrLimit) bytes") }
      guard let exit else { throw failure("Extension timed out after \(deadline)") }
      guard exit.isClean else { throw failure("Extension \(exit)") }
      do {
        if let last = try out.finish() { view(last, false) }
      } catch let error as ExtensionFailure {
        throw failure(error.message)
      } catch {
        // DecodingError's description includes the coding path and missing/incorrect field.
        throw failure(Self.decodingMessage(error))
      }
    } onCancel: {
      stop()
    }
  }
  private static func decodingMessage(_ error: any Error) -> String {
    let context: DecodingError.Context
    let reason: String
    switch error {
    case DecodingError.keyNotFound(let key, let c):
      context = c
      reason = "Missing required field '" + key.stringValue + "'"
    case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c),
      DecodingError.dataCorrupted(let c):
      context = c
      reason = c.debugDescription
    default: return "Invalid extension view: " + error.localizedDescription
    }
    let path = (["$"] + context.codingPath.map(\.stringValue)).joined(separator: ".")
    return "Invalid extension view at " + path + ": " + reason
  }

}

struct ExtensionFailure: LocalizedError, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
