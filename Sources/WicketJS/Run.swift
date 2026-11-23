import Darwin
import Foundation

func runCommand(_ argv: [String], input: Data, maxBytes: Int, deadline: UInt64) throws -> [String: Any] {
  let executable = try commandPath(argv[0])
  let stdin = Pipe()
  let stdout = Pipe()
  let stderr = Pipe()
  let writer = stdin.fileHandleForWriting
  let readers = [stdout.fileHandleForReading, stderr.fileHandleForReading]
  let local = readers.map(\.fileDescriptor) + [writer.fileDescriptor]
  for fd in local {
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw systemError() }
  }
  guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw systemError() }
  _ = try remainingMilliseconds(until: deadline)
  let child = try spawn(
    executable, argv,
    [
      stdin.fileHandleForReading.fileDescriptor, stdout.fileHandleForWriting.fileDescriptor,
      stderr.fileHandleForWriting.fileDescriptor,
    ])
  var reaped = false
  var status: Int32 = 0
  defer {
    if !reaped {
      _ = kill(child, SIGKILL)
      while waitpid(child, &status, 0) < 0 && errno == EINTR {}
    }
  }
  try stdin.fileHandleForReading.close()
  try stdout.fileHandleForWriting.close()
  try stderr.fileHandleForWriting.close()

  var fds = local.enumerated().map {
    pollfd(fd: $0.element, events: Int16($0.offset < 2 ? POLLIN : POLLOUT), revents: 0)
  }
  var outputs = [Data(), Data()]
  var buffer = [UInt8](repeating: 0, count: 16_384)
  var sent = 0
  while true {
    let remaining = try remainingMilliseconds(until: deadline)
    let ended = waitpid(child, &status, WNOHANG)
    if ended < 0 && errno != EINTR { throw systemError() }
    reaped = ended == child
    if fds[2].fd >= 0 && (sent == input.count || reaped) {
      try writer.close()
      fds[2].fd = -1
    }
    if !reaped {
      // A descendant can hold the pipes open after the child exits. Check waitpid between polls.
      let ready = poll(&fds, nfds_t(fds.count), min(remaining, 10))
      if ready < 0 && errno != EINTR { throw systemError() }
      if ready <= 0 { continue }
    }
    for index in readers.indices where fds[index].fd >= 0 && (reaped || fds[index].revents != 0) {
      repeat {
        let count = read(fds[index].fd, &buffer, buffer.count)
        if count > 0 {
          guard count <= maxBytes - outputs[0].count - outputs[1].count else {
            throw Failure("combined output exceeds \(maxBytes) bytes")
          }
          outputs[index].append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
          fds[index].fd = -1
          break
        } else if errno != EINTR {
          guard errno == EAGAIN else { throw systemError() }
          break
        }
      } while reaped
    }
    if reaped { break }
    if fds[2].fd >= 0 && fds[2].revents != 0 {
      let written = input.withUnsafeBytes {
        write(fds[2].fd, $0.baseAddress!.advanced(by: sent), input.count - sent)
      }
      if written >= 0 {
        sent += written
      } else if errno == EPIPE {
        sent = input.count
      } else if errno != EINTR && errno != EAGAIN {
        throw systemError()
      }
    }
  }

  // waitpid encodes the signal in the low seven bits and a normal exit code in the next byte.
  let signal = status & 0x7f
  return [
    "status": signal == 0 ? (status >> 8) & 0xff : NSNull(),
    "signal": signal == 0 ? NSNull() : signal,
    "stdout": String(decoding: outputs[0], as: UTF8.self),
    "stderr": String(decoding: outputs[1], as: UTF8.self),
  ]
}

private func remainingMilliseconds(until deadline: UInt64) throws -> Int32 {
  let now = DispatchTime.now().uptimeNanoseconds
  guard now < deadline else { throw Failure("timed out") }
  return Int32((deadline - now + 999_999) / 1_000_000)
}

private func commandPath(_ name: String) throws -> String {
  guard !name.isEmpty else { throw Failure("expected a program in argv") }
  if name.contains("/") { return name }
  let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
  for folder in path.split(separator: ":", omittingEmptySubsequences: false) {
    let candidate = (folder.isEmpty ? "." : String(folder)) + "/" + name
    var info = stat()
    if stat(candidate, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(candidate, X_OK) == 0 {
      return candidate
    }
  }
  throw Failure("executable not found: \(name)")
}

private func spawn(_ path: String, _ argv: [String], _ descriptors: [Int32]) throws -> pid_t {
  func check(_ result: Int32) throws {
    guard result == 0 else { throw POSIXError(.init(rawValue: result) ?? .EIO) }
  }

  // Process creates a new process group. Spawn directly so Wicket can still clean up descendants.
  var actions: posix_spawn_file_actions_t?
  try check(posix_spawn_file_actions_init(&actions))
  defer { posix_spawn_file_actions_destroy(&actions) }
  for (target, source) in descriptors.enumerated() {
    try check(posix_spawn_file_actions_adddup2(&actions, source, Int32(target)))
  }
  var attributes: posix_spawnattr_t?
  try check(posix_spawnattr_init(&attributes))
  defer { posix_spawnattr_destroy(&attributes) }
  try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))

  var arguments = argv.map { strdup($0) }
  defer { for argument in arguments { free(argument) } }
  guard arguments.allSatisfy({ $0 != nil }) else { throw systemError() }
  arguments.append(nil)
  var child: pid_t = 0
  try check(posix_spawn(&child, path, &actions, &attributes, &arguments, environ))
  return child
}
