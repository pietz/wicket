import CoreServices
import Foundation
import os

/// One Spotlight hit.
struct FileHit: Sendable, Hashable {
  let path: String
  let isFolder: Bool
  let recency: Date?

  init(path: String, isFolder: Bool, recency: Date? = nil) {
    self.path = path
    self.isFolder = isFolder
    self.recency = recency
  }
}

/// The pure half of file search: the Spotlight predicate for an input, which hits are noise and which
/// of the rest are shown. `FilesProvider` runs the query.
enum FileSearch {
  /// Shorter inputs match too much of the disk to be useful.
  static let minimumLength = 2
  /// Per scope group. Spotlight caps each sample before the fuzzy matcher can sort it.
  static let candidates = 500
  /// File rows at the root: enough to find a file, few enough not to bury the apps and commands.
  static let shown = 8

  /// Folders of build output, dependencies, caches or app data, compared case-insensitively.
  static let noiseFolders: Set<String> = [
    "library", "node_modules", "build", "deriveddata", "pods", "__pycache__", "caches",
    "dist", "target", "vendor", "venv", "site-packages", "coverage", "bower_components",
  ]
  /// Packages whose insides are an app's own. Apps themselves are the apps provider's.
  static let opaquePackages: Set<String> = ["app", "photoslibrary"]

  /// Every word of the input as a word prefix of the file name, case and diacritic insensitive
  /// (Spotlight's word mode splits names at spaces, punctuation and camelCase). Nil when too short.
  static func predicate(for input: String) -> String? {
    guard Fold.query(input).count >= minimumLength else { return nil }
    return input.split(whereSeparator: \.isWhitespace)
      .map { "kMDItemFSName == \"\(escaped($0))*\"cdw" }
      .joined(separator: " && ")
  }

  /// Whether a path below a search scope is noise: hidden, a build, dependency, cache or Library
  /// folder or inside one, or an app or inside a package such as an app or a photo library. A file
  /// that merely shares a noise folder's name (`coverage`) is not.
  static func isExcluded(_ relativePath: some StringProtocol, isFolder: Bool) -> Bool {
    let components = relativePath.split(separator: "/")
    return components.enumerated().contains { index, component in
      component.hasPrefix(".")
        || ((isFolder || index < components.count - 1) && noiseFolders.contains(component.lowercased()))
        || opaquePackages.contains((String(component) as NSString).pathExtension.lowercased())
    }
  }

  /// The best `shown` hits by file name as rows, noise dropped. A file that can be opened opens and
  /// reveals; one that `OpenPolicy` refuses, such as a script, can only be revealed.
  static func rows(_ hits: [FileHit], input: String, scopes: [String], home: String) -> [Row] {
    let (query, words) = (Fold.query(input), Fold.words(input))
    // Byte comparisons and precomputed lengths keep scope checks and sorting off the Unicode slow path.
    let prefixes = scopes.map { Array(($0 + "/").utf8) }
    var seen: Set<String> = []
    seen.reserveCapacity(hits.count)
    var scored: [(hit: FileHit, name: String, length: Int, score: Int)] = []
    for hit in hits {
      guard seen.insert(hit.path).inserted else { continue }
      let path = hit.path.utf8
      guard let prefix = prefixes.first(where: { path.starts(with: $0) }),
        !isExcluded(
          hit.path[path.index(path.startIndex, offsetBy: prefix.count)...], isFolder: hit.isFolder)
      else { continue }
      let name = (hit.path as NSString).lastPathComponent
      guard let score = FuzzyMatcher.score(query, words: words, SearchKey(name)) else { continue }
      // Characters, as the user sees the name, counted once per hit and not in the sort.
      let length = (hit.isFolder ? name : (name as NSString).deletingPathExtension).count
      scored.append((hit, name, length, score))
    }
    scored.sort { a, b in
      if a.score != b.score { return a.score > b.score }
      if a.hit.recency != b.hit.recency {
        guard let newer = a.hit.recency else { return false }
        guard let older = b.hit.recency else { return true }
        return newer > older
      }
      if a.length != b.length { return a.length < b.length }
      return a.hit.path.utf8.lexicographicallyPrecedes(b.hit.path.utf8)
    }
    return scored.prefix(shown).map { hit, name, _, _ in
      let url = URL(filePath: hit.path, directoryHint: hit.isFolder ? .isDirectory : .notDirectory)
      return Row(
        id: hit.path, title: name, subtitle: displayFolder(of: hit.path, home: home),
        actions: OpenPolicy.allowed(url) ? [.open(url), .reveal(url)] : [.reveal(url)])
    }
  }

  private static let iCloudDrive = "/Library/Mobile Documents/com~apple~CloudDocs"
  private static let cloudStorage = "/Library/CloudStorage"

  /// The folder under a file's name: "~/Documents/Taxes", "iCloud Drive/Notes", "/Volumes/Disk".
  static func displayFolder(of path: String, home: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    let iCloud = home + iCloudDrive
    if parent == iCloud || parent.hasPrefix(iCloud + "/") {
      return "iCloud Drive" + parent.dropFirst(iCloud.count)
    }
    if parent == home || parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
    return parent
  }

  /// The folders to search, read per query during the debounce, so new folders and volumes are picked
  /// up at no cost to latency. Each visible folder in home is its own scope, so Spotlight never walks
  /// ~/Library. Loose files directly in home are missed, because a scope must be a folder.
  static func scopes(home: String) -> [String] {
    let fm = FileManager.default
    let folders =
      (try? fm.contentsOfDirectory(
        at: URL(filePath: home, directoryHint: .isDirectory), includingPropertiesForKeys: [.isDirectoryKey]))?
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .filter { !isExcluded($0.lastPathComponent, isFolder: true) }
      .map(\.path) ?? []
    let clouds = [iCloudDrive, cloudStorage]
      .map { home + $0 }
      .filter { fm.fileExists(atPath: $0) }
    let volumes =
      fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?
      .map(\.path).filter { $0.hasPrefix("/Volumes/") } ?? []
    return folders + clouds + volumes
  }

  /// Separate caps keep matches from other folders from filling the personal folders' sample.
  static func scopeGroups(_ scopes: [String], home: String) -> [[String]] {
    let personal = Set(["/Desktop", "/Documents", "/Downloads", iCloudDrive, cloudStorage].map { home + $0 })
    return [scopes.filter { personal.contains($0) }, scopes.filter { !personal.contains($0) }]
      .filter { !$0.isEmpty }
  }

  /// Spotlight query strings take a backslash before quotes, backslashes and wildcards.
  private static func escaped(_ word: Substring) -> String {
    var result = ""
    for character in word {
      if "\"\\*?".contains(character) { result.append("\\") }
      result.append(character)
    }
    return result
  }
}

/// Files and folders by name, from the Spotlight index, as batches of rows: each batch replaces the
/// previous one. Row ids are paths. Spotlight is the one hardware-like edge, so tests pass a fake
/// `search`.
final class FilesProvider: Sendable {
  typealias Search =
    @Sendable (_ predicate: String, _ scopes: [String], _ limit: Int) -> AsyncStream<[FileHit]>
  let id = "files"
  private let search: Search
  private let scopes: @Sendable () -> [String]
  private let home: String
  /// How long the input must stay unchanged before Spotlight is asked, so fast typing does not
  /// start a query per keystroke.
  private let debounce: Duration
  private static let logger = Logger(subsystem: "app.wicket", category: "files")

  init(
    search: @escaping Search = Spotlight.hits, home: String = NSHomeDirectory(),
    scopes: (@Sendable () -> [String])? = nil, debounce: Duration = .milliseconds(80)
  ) {
    self.search = search
    self.home = home
    self.scopes = scopes ?? { FileSearch.scopes(home: home) }
    self.debounce = debounce
  }

  /// Ends at once when the input is too short to search. Ending the iteration, or cancelling the task
  /// that iterates, stops both queries, also during the debounce.
  func batches(for input: String) -> AsyncStream<[Row]> {
    let (search, scopes, home, debounce) = (search, scopes, home, debounce)
    return AsyncStream { continuation in
      guard let predicate = FileSearch.predicate(for: input) else { return continuation.finish() }
      let task = Task.detached(priority: .userInitiated) {
        defer { continuation.finish() }
        // Read before the debounce ends, so their 3 to 6 ms cost no latency.
        let scopes = scopes()
        let groups = FileSearch.scopeGroups(scopes, home: home)
        guard (try? await Task.sleep(for: debounce)) != nil else { return }
        let start = ContinuousClock.now
        let (updates, feed) = AsyncStream.makeStream(of: (Int, [FileHit]).self)
        async let queries: Void = withTaskGroup(of: Void.self) { tasks in
          for (index, locations) in groups.enumerated() {
            tasks.addTask {
              guard !Task.isCancelled else { return }
              for await hits in search(predicate, locations, FileSearch.candidates) {
                guard !Task.isCancelled else { return }
                feed.yield((index, hits))
              }
            }
          }
          await tasks.waitForAll()
          feed.finish()
        }
        var latest = [[FileHit]](repeating: [], count: groups.count)
        var first = true
        for await (index, hits) in updates {
          guard !Task.isCancelled else { return }
          latest[index] = hits
          let merged = latest.flatMap { $0 }
          let rows = FileSearch.rows(merged, input: input, scopes: scopes, home: home)
          continuation.yield(rows)
          if first {
            first = false
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            Self.logger.info(
              "files: first batch \(rows.count, privacy: .public) of \(merged.count, privacy: .public) in \(ms, format: .fixed(precision: 1), privacy: .public) ms"
            )
          }
        }
        await queries
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// Searches of the Spotlight index through the MDQuery C API. MDQuery rather than `NSMetadataQuery`:
/// it caps hits inside Spotlight (`MDQuerySetMaxCount`), notifies on our own serial queue instead of a
/// run loop, and stops synchronously.
enum Spotlight {
  /// Items matching `predicate` under `scopes`, at most `limit`. Each element holds every hit gathered
  /// so far, and the stream finishes when gathering does. Terminating it stops the query.
  static func hits(matching predicate: String, in scopes: [String], limit: Int) -> AsyncStream<[FileHit]> {
    AsyncStream { continuation in
      let search = SpotlightSearch(continuation: continuation)
      continuation.onTermination = { _ in search.stop() }
      search.start(predicate, scopes: scopes, limit: limit)
    }
  }
}

/// One running query. Its state is only touched on `queue`, where MDQuery also posts its
/// notifications, which is what makes the unchecked `Sendable` sound.
private final class SpotlightSearch: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.wicket.spotlight", qos: .userInitiated)
  private let continuation: AsyncStream<[FileHit]>.Continuation
  private var query: MDQuery?
  private var observers: [any NSObjectProtocol] = []
  private var stopped = false

  init(continuation: AsyncStream<[FileHit]>.Continuation) { self.continuation = continuation }

  func start(_ predicate: String, scopes: [String], limit: Int) {
    queue.async { [self] in
      guard !stopped,
        let query = MDQueryCreate(
          kCFAllocatorDefault, predicate as CFString,
          [kMDItemContentType, kMDItemLastUsedDate, kMDItemDateAdded] as CFArray, nil)
      else { return continuation.finish() }
      self.query = query
      MDQuerySetSearchScope(query, scopes as CFArray, 0)
      MDQuerySetMaxCount(query, limit)
      MDQuerySetDispatchQueue(query, queue)
      for (name, final) in [(kMDQueryProgressNotification, false), (kMDQueryDidFinishNotification, true)] {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: Notification.Name(name! as String), object: query, queue: nil
          ) { [self] _ in publish(final: final) })
      }
      // No kMDQueryWantsUpdates: gather once, never watch for changes.
      if !MDQueryExecute(query, 0) { continuation.finish() }
    }
  }

  func stop() {
    queue.async { [self] in
      stopped = true
      guard let query else { return }
      MDQueryStop(query)
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers = []
      self.query = nil
    }
  }

  private func publish(final: Bool) {
    guard let query else { return }
    let hits = (0..<MDQueryGetResultCount(query)).compactMap { index -> FileHit? in
      guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
      let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
      guard var path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
      // Native UTF-8 once here instead of a bridged string that every later byte comparison converts.
      path.makeContiguousUTF8()
      // Read from the value list Spotlight gathered with the results: copying it per item costs an
      // IPC round trip each, about 0.4 ms.
      let type = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemContentType, index).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
      }
      func date(_ attribute: CFString) -> Date? {
        guard let value = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue() as? Date
      }
      let recency = date(kMDItemLastUsedDate) ?? date(kMDItemDateAdded)
      return FileHit(path: path, isFolder: type == "public.folder", recency: recency)
    }
    continuation.yield(hits)
    if final { continuation.finish() }
  }
}
