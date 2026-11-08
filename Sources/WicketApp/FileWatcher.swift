import CoreServices
import Foundation

/// Calls `onChange` on the main actor with the changed folders when anything under `paths` changes,
/// coalesced over `latency`. FSEvents watches by path, so a folder that does not exist yet is picked
/// up once it is created. When FSEvents can't say what changed (events dropped, ids wrapped) the
/// watched paths themselves are reported, so a receiver treats it as a change at the root; a root
/// that changed (moved, replaced) or must be rescanned is reported as itself too.
@MainActor
final class FileWatcher {
    private let paths: [String]
    private let onChange: @MainActor ([String]) -> Void
    private var stream: FSEventStreamRef?

    nonisolated private static let lostTrack = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped)

    init(paths: [String], latency: TimeInterval, onChange: @escaping @MainActor ([String]) -> Void) {
        self.paths = paths
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
            MainActor.assumeIsolated { watcher.onChange(changed) }
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
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
