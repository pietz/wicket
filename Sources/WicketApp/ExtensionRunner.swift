import Foundation
import Synchronization

/// Counts every byte as it arrives and keeps what the limit allows. The reader stops at the limit and
/// stops the process at once.
private final class ExtensionOutput: Sendable {
  struct State {
    var data = Data()
    var count = 0
  }
  private let state = Mutex(State())
  let limit: Int
  let tail: Bool
  init(limit: Int, tail: Bool = false) {
    self.limit = limit
    self.tail = tail
  }
  func read(_ handle: FileHandle, overflow: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    Task {
      for await chunk in handle.chunks(limit: limit, exceeded: overflow) {
        state.withLock { state in
          state.count += chunk.count
          if self.tail {
            state.data = Data((state.data + chunk).suffix(4096))
          } else if state.count <= self.limit {
            state.data.append(chunk)
          }
        }
      }
    }
  }
  var data: Data { state.withLock { $0.data } }
  var exceeded: Bool { state.withLock { $0.count > limit } }
}

struct ExtensionRunner: Sendable {
  var deadline: Duration = .seconds(10)
  var outputLimit = 1_048_576
  var stderrLimit = 262_144

  func run(_ command: ExtensionCommand, request: ProviderRequest) async throws -> ProviderView {
    try Task.checkCancellation()
    // The host answers a command without a program itself and never runs it.
    guard let argv = command.manifest.command else { throw ExtensionFailure("No command to run") }
    var environment = Launch.environment()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    let executable: URL
    if argv[0].contains("/") {
      executable =
        argv[0].hasPrefix("/") ? URL(fileURLWithPath: argv[0]) : command.folder.appending(path: argv[0])
    } else {
      guard let found = Launch.which(argv[0], in: environment) else {
        throw ExtensionFailure("Executable not found: \(argv[0])")
      }
      executable = found
    }
    let started = try Launch.start(
      executable, Array(argv.dropFirst()), in: command.folder, environment: environment)
    let tree = started.tree
    let out = ExtensionOutput(limit: outputLimit)
    let err = ExtensionOutput(limit: stderrLimit, tail: true)
    let stop: @Sendable () -> Void = { _ = tree.stop(after: .zero, grace: .milliseconds(100)) }
    let stdout = out.read(started.stdout, overflow: stop)
    let stderr = err.read(started.stderr, overflow: stop)
    tree.write(try JSONEncoder().encode(request) + Data([10]))
    tree.closeInput()
    return try await withTaskCancellationHandler {
      let exit = await tree.exit.value(within: deadline)
      _ = await tree.stop(after: .zero, grace: .milliseconds(100)).value
      await stdout.value
      await stderr.value
      try Task.checkCancellation()
      let diagnostic = String(decoding: err.data, as: UTF8.self)
      func failure(_ message: String) -> ExtensionFailure {
        ExtensionFailure(message + (diagnostic.isEmpty ? "" : "\n\nStderr (last 4 KiB):\n" + diagnostic))
      }
      if out.exceeded { throw failure("Extension stdout exceeded \(outputLimit) bytes") }
      if err.exceeded { throw failure("Extension stderr exceeded \(stderrLimit) bytes") }
      guard let exit else { throw failure("Extension timed out after \(deadline)") }
      guard exit.isClean else { throw failure("Extension \(exit)") }
      // A view is JSON, which starts with `{`, and a broken one stays an error. Anything else is Markdown.
      let text = String(decoding: out.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw failure("Extension printed nothing") }
      guard text.hasPrefix("{") else { return ProviderView(reply: text) }
      do { return try JSONDecoder().decode(ProviderView.self, from: out.data) } catch {
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
