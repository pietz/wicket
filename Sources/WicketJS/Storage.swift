import Darwin
import Foundation

private let limit = 1_048_576

private func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

func dataFile(_ name: String) throws -> URL {
  guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(UInt8(ascii: "/")),
    !name.utf8.contains(0)
  else {
    throw Failure("expected a single filename")
  }
  guard let path = ProcessInfo.processInfo.environment["WICKET_DATA_DIR"], !path.isEmpty else {
    throw Failure("WICKET_DATA_DIR is missing")
  }
  return URL(fileURLWithPath: path, isDirectory: true).appending(path: name)
}

func readData(from file: URL) throws -> String? {
  // Nonblocking open lets fstat reject a FIFO even when nobody has opened its other end.
  let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  if fd < 0 {
    if errno == ENOENT { return nil }
    throw systemError()
  }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  var info = stat()
  guard fstat(fd, &info) == 0 else { throw systemError() }
  try checkRegularFile(info)
  guard info.st_size <= limit else { throw Failure("file exceeds 1 MiB") }
  let bytes = try handle.read(upToCount: limit + 1) ?? Data()
  guard bytes.count <= limit else { throw Failure("file exceeds 1 MiB") }
  guard let text = String(data: bytes, encoding: .utf8) else { throw Failure("file is not UTF-8") }
  return text
}

func writeData(_ text: String, to file: URL) throws {
  let bytes = Data(text.utf8)
  guard bytes.count <= limit else { throw Failure("text exceeds 1 MiB") }
  var info = stat()
  if lstat(file.path, &info) == 0 {
    try checkRegularFile(info)
  } else if errno != ENOENT {
    throw systemError()
  }

  var temporary = Array(
    file.deletingLastPathComponent().appending(path: ".wicket-js.XXXXXX").path.utf8CString)
  let fd = mkstemp(&temporary)
  guard fd >= 0 else { throw systemError() }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  defer { unlink(temporary) }
  try handle.write(contentsOf: bytes)
  try handle.close()
  guard rename(temporary, file.path) == 0 else { throw systemError() }
}

private func checkRegularFile(_ info: stat) throws {
  guard info.st_mode & S_IFMT == S_IFREG else { throw Failure("expected a regular file") }
}
