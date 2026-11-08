import Foundation
import WicketCore

/// Files and folders by name, from the Spotlight index. Item ids are "files:" plus the path.
///
/// Searches the home folder (minus Library and hidden folders, plus iCloud Drive and cloud storage
/// providers) and mounted volumes. Home's own entries are listed directly, since a Spotlight scope
/// must be a folder and home as a whole would mean walking ~/Library. Spotlight caps hits at
/// `candidates` before any sorting, so it returns an arbitrary sample of a large match set; the
/// shared fuzzy matcher picks the best of them.
@MainActor
final class FilesSource: ResultSource {
    let id = "files"
    /// How long the query must stay unchanged before Spotlight is asked, so fast typing doesn't
    /// start a query per keystroke.
    nonisolated private static let debounce = Duration.milliseconds(80)
    nonisolated private static let candidates = 500

    /// Spotlight is never memory-only.
    func instant(_ query: Query) -> [Item] { [] }

    func updates(_ query: Query) -> AsyncStream<[Item]>? {
        guard let predicate = FileSearch.predicate(for: query.text) else { return nil }
        let text = query.text
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                let start = ContinuousClock.now
                let home = NSHomeDirectory()
                let entries = Self.homeEntries(home)
                let scopes = Self.scopes(home: home, entries: entries)
                var first = true
                // Cancelling this task ends the iteration, which terminates and stops the Spotlight query.
                for await hits in Spotlight.hits(matching: predicate, in: scopes, limit: Self.candidates) {
                    let items = FileSearch.items(entries + hits, query: text, scopes: scopes, home: home)
                    continuation.yield(items)
                    if first {
                        first = false
                        Perf.log(
                            "files: first batch, \(items.count) of \(hits.count) in \(Perf.ms(since: start))")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Home's visible entries, files and folders, read per query so new ones are picked up.
    nonisolated private static func homeEntries(_ home: String) -> [FileSearch.Hit] {
        let homeURL = URL(filePath: home, directoryHint: .isDirectory)
        return
            (try? FileManager.default.contentsOfDirectory(
                at: homeURL, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { !FileSearch.isExcluded($0.lastPathComponent) }
            .map {
                FileSearch.Hit(
                    path: $0.path,
                    isFolder: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            } ?? []
    }

    /// The folders to search, read per query so new volumes are picked up.
    nonisolated private static func scopes(home: String, entries: [FileSearch.Hit]) -> [String] {
        let fm = FileManager.default
        // Each visible folder in home is its own scope, so Spotlight never walks ~/Library.
        let folders = entries.filter(\.isFolder).map(\.path)
        let clouds = ["Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage"]
            .map { home + "/" + $0 }
            .filter { fm.fileExists(atPath: $0) }
        let volumes =
            fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?
            .map(\.path)
            .filter { $0.hasPrefix("/Volumes/") } ?? []
        return folders + clouds + volumes
    }
}
