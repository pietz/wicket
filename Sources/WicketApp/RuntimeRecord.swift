import Darwin
import Foundation

struct RuntimeRecord: Codable, Sendable {
  struct PermissionCheck: Codable, Sendable {
    let status: Permission.Status
    let checkedAt: Date
  }
  struct VoiceFailure: Codable, Sendable {
    let at: Date
    let errorCase: String
    let osDomain: String?
    let osCode: Int?
    let stopReason: String
  }
  enum Trigger: String, Codable, Sendable {
    case command, hotkey, item
    case hiddenRun = "hidden run"
    case rootPattern = "root pattern"
  }
  struct ExtensionFailure: Codable, Sendable {
    let at: Date
    let extensionID: String
    let trigger: Trigger
    let action: String?
    let message: String
    let exitCode: Int32?
    let stderrTail: String?
  }

  struct ProcessIdentity: Equatable, Sendable {
    let executablePath: String
    let startTimeMicroseconds: UInt64

    static func read(_ pid: Int32) -> Self? {
      guard pid > 0 else { return nil }
      // PROC_PIDPATHINFO_MAXSIZE is a C macro that Swift doesn't import.
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
      guard count > 0, let start = ProcessTree.startTime(of: pid) else { return nil }
      return Self(
        executablePath: String(
          decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        startTimeMicroseconds: start)
    }
  }

  let pid: Int32
  // Optional so a record from an earlier build can still be read as history.
  var executablePath: String? = nil
  var bundlePath: String? = nil
  var processStartTimeMicroseconds: UInt64? = nil
  var updatedAt: Date
  var permissions: [String: PermissionCheck] = [:]
  var registrations: HotkeyRegistrations?
  var hotkeyProblem: String?
  var bindingProblem: String?
  var lastVoiceFailure: VoiceFailure?
  var recentFailures: [ExtensionFailure] = []

  func isLive(process: (Int32) -> ProcessIdentity?) -> Bool {
    guard let executablePath, let processStartTimeMicroseconds else { return false }
    return process(pid)
      == .init(
        executablePath: executablePath, startTimeMicroseconds: processStartTimeMicroseconds)
  }

  static func url(beside log: AgentLog) -> URL {
    log.file.deletingLastPathComponent().appending(path: "runtime.json")
  }

  static func read(_ url: URL) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: Data(contentsOf: url))
  }
}

/// The app's most recent observations. Tests can omit the writer and inspect the same record in memory.
@MainActor
final class RuntimeRecorder {
  private(set) var record: RuntimeRecord
  private var permissionCheck: Task<Void, Never>?
  private let writer: LatestWriter<RuntimeRecord>?

  init(url: URL? = nil) {
    let pid = getpid()
    let process = RuntimeRecord.ProcessIdentity.read(pid)
    record = RuntimeRecord(
      pid: pid, executablePath: process?.executablePath ?? Bundle.main.executableURL?.path,
      bundlePath: Bundle.main.bundleURL.path, processStartTimeMicroseconds: process?.startTimeMicroseconds,
      updatedAt: Date())
    writer = url.map { url in
      LatestWriter { record in
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        if data.count <= 256 * 1024 {
          try? Self.writePrivate(data, to: url)
        } else {
          // Extremely large hand-edited hotkey tables must not crowd out recent failures.
          var record = record
          record.registrations = nil
          try? Self.writePrivate(encoder.encode(record), to: url)
        }
      }
    }
  }

  func refreshPermissions(_ permissions: Permissions) {
    guard permissionCheck == nil else { return }
    permissionCheck = Task {
      let snapshot = await Task.detached { permissions.snapshot() }.value
      observePermissions(snapshot)
      permissionCheck = nil
    }
  }

  func observePermissions(_ live: [String: Permission.Status]) {
    let changed = record.permissions.mapValues(\.status) != live
    let now = Date()
    record.permissions = live.mapValues { .init(status: $0, checkedAt: now) }
    if changed { save() }
  }

  func register(_ registrations: HotkeyRegistrations) {
    guard registrations != record.registrations else { return }
    record.registrations = registrations
    record.hotkeyProblem = registrations.launcher.problem
    record.bindingProblem = registrations.bindingProblem.map {
      String(decoding: $0.utf8.prefix(8192), as: UTF8.self)
    }
    save()
  }

  func voiceFailed(_ error: any Error, reason: VoiceStop) {
    let system = error as? VoiceSystemError
    let voice = system?.category ?? error as? VoiceError
    let os = voice == nil ? error as NSError : nil
    let domain = system?.domain ?? os?.domain
    record.lastVoiceFailure = .init(
      at: Date(), errorCase: voice?.rawValue ?? "systemError",
      osDomain: domain.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) },
      osCode: system?.code ?? os?.code,
      stopReason: reason.rawValue)
    save()
  }

  func extensionFailed(_ id: String, trigger: RuntimeRecord.Trigger, action: String?, error: any Error) {
    let failure = error as? ExtensionFailure
    let tail = (failure?.stderr ?? "").utf8.suffix(2048).drop { $0 & 0xC0 == 0x80 }
    record.recentFailures.append(
      .init(
        at: Date(), extensionID: id, trigger: trigger,
        action: action.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) },
        message: String(
          decoding: (failure?.message ?? error.localizedDescription).utf8.prefix(2048), as: UTF8.self),
        exitCode: failure?.exitCode, stderrTail: tail.isEmpty ? nil : String(decoding: tail, as: UTF8.self)))
    if record.recentFailures.count > 10 { record.recentFailures.removeFirst() }
    save()
  }

  private func save() {
    record.updatedAt = Date()
    writer?.submit(record)
  }

  func finish() async {
    await permissionCheck?.value
    await writer?.finish()
  }

  nonisolated private static func writePrivate(_ data: Data, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var template = folder.appending(path: ".runtime.XXXXXX").path.utf8CString
    let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    guard fd >= 0 else { return }
    let name = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      _ = unlink(name)
    }
    guard fchmod(fd, 0o600) == 0 else { return }
    try handle.write(contentsOf: data)
    _ = rename(name, url.path)
  }
}
