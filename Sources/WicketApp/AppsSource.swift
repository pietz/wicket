import AppKit
import WicketCore

struct AppRecord: Sendable, Hashable {
    let url: URL
    let name: String
    let alternates: [String]
}

/// Applications found by scanning fixed folders, refreshed by FSEvents.
/// Item ids are "apps:" plus the bundle path.
///
/// Scanning known folders (rather than an `NSMetadataQuery` over the Spotlight index) is fast,
/// deterministic and works with Spotlight indexing off; a Spotlight query also returns copies in
/// Downloads, build folders, backups and mounted images.
@MainActor
final class AppsSource: ResultSource {
    let id = "apps"
    var onChange: (() -> Void)?

    private var apps: [AppRecord] = []
    private var index = SearchIndex([])

    private var watcher: FileWatcher?
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

    /// Scans, then watches the folders for changes. Called once, at launch.
    func start() async {
        await rescan()
        watch()
    }

    func instant(_ query: Query) -> [Item] {
        index.search(query.text)
    }

    func rescan() async {
        let start = ContinuousClock.now
        let (found, index) = await Task.detached(priority: .userInitiated) {
            let found = Self.scan(Self.scopes)
            return (found, Self.index(found))
        }.value
        Perf.log("app scan: \(found.count) apps in \(Perf.ms(since: start))")
        guard found != apps else { return }
        apps = found
        self.index = index
        onChange?()
    }

    nonisolated static func index(_ apps: [AppRecord]) -> SearchIndex {
        SearchIndex(
            apps.map { app in
                let item = Item(
                    id: "apps:" + app.url.path, title: app.name, icon: .file(url: app.url),
                    accessory: "Application", actions: Item.Action.forFile(app.url))
                return (item, app.alternates)
            })
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
        let paths = Self.scopes.filter { !$0.hasSuffix(".app") }
        watcher = FileWatcher(paths: paths, latency: 1.0) { [weak self] _ in self?.scheduleRescan() }
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
