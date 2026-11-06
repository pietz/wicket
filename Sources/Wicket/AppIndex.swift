import AppKit
import CoreServices
import WicketCore

struct AppRecord: Sendable, Hashable {
    let url: URL
    let name: String
    let alternates: [String]
}

/// Applications found by scanning fixed folders, refreshed by FSEvents.
///
/// Scanning known folders (rather than an `NSMetadataQuery` over the Spotlight index) is fast,
/// deterministic and works with Spotlight indexing off; a Spotlight query also returns copies in
/// Downloads, build folders, backups and mounted images.
@MainActor
final class AppIndex {
    private(set) var apps: [AppRecord] = []
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var rescanTask: Task<Void, Never>?

    nonisolated static let scopes: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        // Safari lives here; /Applications/Safari.app is a hidden symlink.
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
        "/System/Library/CoreServices/Finder.app",
        NSHomeDirectory() + "/Applications",
    ]

    func start() async {
        await rescan()
        watch()
    }

    func rescan() async {
        let start = ContinuousClock.now
        let found = await Task.detached(priority: .userInitiated) { Self.scan(Self.scopes) }.value
        Perf.log("app scan: \(found.count) apps in \(Perf.ms(since: start))")
        guard found != apps else { return }
        apps = found
        onChange?()
    }

    // MARK: Scanning

    nonisolated static func scan(_ scopes: [String]) -> [AppRecord] {
        let fm = FileManager.default
        var seen = Set<String>()
        var records: [AppRecord] = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            records.append(record(for: url))
            // Apps shipped inside apps: Simulator and Instruments inside Xcode.
            for inner in ["Contents/Applications", "Contents/Developer/Applications"] {
                for child in appChildren(of: url.appending(path: inner), fm: fm) {
                    if seen.insert(child.standardizedFileURL.path).inserted {
                        records.append(record(for: child))
                    }
                }
            }
        }

        for scope in scopes {
            let url = URL(fileURLWithPath: scope)
            if url.pathExtension == "app" {
                if fm.fileExists(atPath: scope) { add(url) }
                continue
            }
            guard
                let children = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for child in children {
                if child.pathExtension == "app" {
                    add(child)
                } else if isPlainDirectory(child) {
                    // One level deep for vendor folders like "/Applications/Adobe Photoshop 2026/".
                    for nested in appChildren(of: child, fm: fm) { add(nested) }
                }
            }
        }
        return records
    }

    nonisolated private static func appChildren(of folder: URL, fm: FileManager) -> [URL] {
        guard
            let children = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return children.filter { $0.pathExtension == "app" }
    }

    nonisolated private static func isPlainDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    nonisolated private static func record(for url: URL) -> AppRecord {
        let fileName = url.deletingPathExtension().lastPathComponent
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        var alternates: [String] = []
        if name != fileName { alternates.append(fileName) }
        return AppRecord(url: url, name: name, alternates: alternates)
    }

    // MARK: Watching

    private func watch() {
        let paths = Self.scopes.filter { !$0.hasSuffix(".app") } as CFArray
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let index = Unmanaged<AppIndex>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { index.scheduleRescan() }
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.rescan()
        }
    }
}
