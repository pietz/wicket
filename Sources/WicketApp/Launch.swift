import Foundation

/// How every child process starts: one PATH, one lookup, three pipes, one process tree.
enum Launch {
  struct Started {
    let tree: ProcessTree
    let stdout: FileHandle
    let stderr: FileHandle
  }

  /// The environment's PATH, then the folders where Homebrew, npm and the CLI installers put tools,
  /// which an app started from the Dock lacks.
  static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var environment = base
    environment["PATH"] =
      ((base["PATH"] ?? "").split(separator: ":").map(String.init) + [
        home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin",
      ]).joined(separator: ":")
    return environment
  }

  /// The first executable called `name` on that PATH.
  static func which(_ name: String, in environment: [String: String] = environment()) -> URL? {
    environment["PATH"]?.split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appending(path: name) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static func start(
    _ executable: URL, _ arguments: [String], in folder: URL, environment: [String: String]
  ) throws -> Started {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    return Started(
      tree: try ProcessTree(launching: process), stdout: output.fileHandleForReading,
      stderr: errors.fileHandleForReading)
  }

  /// Runs a short command to its end: its exit and stdout, or nil if it outlasts `limit`.
  static func capture(
    _ executable: URL, _ arguments: [String], in folder: URL, limit: Duration, input: Data? = nil
  )
    async throws -> (exit: Exit, output: Data)?
  {
    let started = try start(executable, arguments, in: folder, environment: environment())
    // Read concurrently, so a full diagnostic pipe cannot deadlock the deadline.
    let output = started.stdout.collect()
    let diagnostic = Task { for await _ in started.stderr.chunks() {} }
    if let input { started.tree.write(input) }
    started.tree.closeInput()
    let exit = await started.tree.exit.value(within: limit)
    _ = await started.tree.stop(after: .zero, grace: .milliseconds(100)).value
    _ = await diagnostic.value
    let data = await output.value.data
    return exit.map { ($0, data) }
  }
}

extension FileHandle {
  func collect(limit: Int = .max, tail: Bool = false, overflow: @escaping @Sendable () -> Void = {})
    -> Task<(data: Data, exceeded: Bool), Never>
  {
    Task {
      var data = Data()
      var count = 0
      for await chunk in chunks(limit: limit, exceeded: overflow) {
        count += chunk.count
        if tail {
          data.appendStderr(chunk)
        } else if count <= limit {
          data.append(chunk)
        }
      }
      return (data, count > limit)
    }
  }

  /// The bytes as they arrive, until EOF. Blocking reads run on a Dispatch queue, so a pipe
  /// nobody writes to never holds a thread of Swift's cooperative pool.
  ///
  /// Reading is bounded where it happens, not after the bytes are queued: once more than `limit`
  /// bytes have arrived (`perLine`: since the last newline), that chunk is the last one. Reading
  /// stops, the stream ends and `exceeded` runs, so a flood never queues beyond the limit.
  func chunks(limit: Int = .max, perLine: Bool = false, exceeded: @escaping @Sendable () -> Void = {})
    -> AsyncStream<Data>
  {
    AsyncStream { continuation in
      DispatchQueue.global().async {
        var run = 0
        while case let data = self.availableData, !data.isEmpty {
          continuation.yield(data)
          if perLine, let newline = data.lastIndex(of: 10) {
            run = data.endIndex - 1 - newline
          } else {
            run += data.count
          }
          if run > limit {
            exceeded()
            break
          }
        }
        continuation.finish()
      }
    }
  }
}

extension Data {
  /// Keep bytes until the diagnostic is read, since a UTF-8 character can span chunks.
  mutating func appendStderr(_ chunk: Data) {
    append(chunk)
    if count > 4096 { self = Data(suffix(4096)) }
  }
}
