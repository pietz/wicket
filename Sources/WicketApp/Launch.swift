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
  static func capture(_ executable: URL, _ arguments: [String], in folder: URL, limit: Duration)
    async throws -> (exit: Exit, output: Data)?
  {
    let started = try start(executable, arguments, in: folder, environment: environment())
    started.tree.closeInput()
    // Read concurrently, so a full diagnostic pipe cannot deadlock the deadline.
    let output = Task {
      var data = Data()
      for await chunk in started.stdout.chunks() { data.append(chunk) }
      return data
    }
    let diagnostic = Task { for await _ in started.stderr.chunks() {} }
    let exit = await started.tree.exit.value(within: limit)
    _ = await started.tree.stop(after: .zero, grace: .milliseconds(100)).value
    _ = await diagnostic.value
    let data = await output.value
    return exit.map { ($0, data) }
  }
}

extension FileHandle {
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
