import CoreServices
import Foundation

/// Coalesced FSEvents, optionally filtered to exact files, including atomic replacement.
@MainActor
final class FileWatcher {
  private let paths: [String]
  private let filesOnly: Bool
  private let onChange: @MainActor ([String]) -> Void
  private var stream: FSEventStreamRef?

  nonisolated private static let lostTrack = FSEventStreamEventFlags(
    kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
      | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)

  init(
    paths: [String], latency: TimeInterval, filesOnly: Bool = false,
    onChange: @escaping @MainActor ([String]) -> Void
  ) {
    self.paths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    self.filesOnly = filesOnly
    self.onChange = onChange
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
      var changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      if UnsafeBufferPointer(start: flags, count: count).contains(where: {
        $0 & FileWatcher.lostTrack != 0
      }) {
        changed += watcher.paths
      }
      if watcher.filesOnly {
        changed = changed.filter {
          watcher.paths.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        }
      }
      if !changed.isEmpty { MainActor.assumeIsolated { watcher.onChange(changed) } }
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context,
        (filesOnly
          ? Array(Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })) : paths)
          as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            | (filesOnly ? kFSEventStreamCreateFlagFileEvents : 0)))
    else { return }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  isolated deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
