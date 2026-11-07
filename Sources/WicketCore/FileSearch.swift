import Foundation

/// The pure half of file search: the Spotlight predicate for a query, which hits are noise, and how
/// the rest score against other sources. `FilesSource` runs the query.
public enum FileSearch {
    /// One Spotlight hit.
    public struct Hit: Sendable, Hashable {
        public var path: String
        public var isFolder: Bool

        public init(path: String, isFolder: Bool) {
            self.path = path
            self.isFolder = isFolder
        }
    }

    /// Shorter queries match too much of the disk to be useful.
    public static let minimumQueryLength = 2
    public static let limit = 20
    /// Subtracted from a file's fuzzy score so an app or command that matches about as well ranks
    /// above it. One prefix bonus: a file whose name starts with the query still beats an app the
    /// query only scatters across, but never an app it is equally a prefix of.
    public static let penalty = Double(FuzzyMatcher.Weight.prefix)

    /// Folders full of build output, dependencies, caches or app data, compared case-insensitively.
    static let noiseFolders: Set<String> = [
        "library", "node_modules", "build", "deriveddata", "pods", "__pycache__", "caches",
    ]
    /// Package extensions whose contents are an app's own: apps (`AppsSource` lists those) and
    /// photo libraries.
    static let opaquePackages: Set<String> = ["app", "photoslibrary"]

    /// Every word of the query as a word prefix of the file name, case and diacritic insensitive
    /// (Spotlight's word mode splits names at spaces, punctuation and camelCase). Nil when the query
    /// is too short.
    public static func predicate(for text: String) -> String? {
        guard Fold.query(text).count >= minimumQueryLength else { return nil }
        return text.split(whereSeparator: \.isWhitespace)
            .map { "kMDItemFSName == \"\(escaped($0))*\"cdw" }
            .joined(separator: " && ")
    }

    /// Whether `relativePath`, below a search scope, is noise: hidden, inside a build, dependency
    /// or cache folder, or an app or inside a package such as an app.
    public static func isExcluded(_ relativePath: some StringProtocol) -> Bool {
        relativePath.split(separator: "/").contains { component in
            component.hasPrefix(".") || noiseFolders.contains(component.lowercased())
                || opaquePackages.contains((String(component) as NSString).pathExtension.lowercased())
        }
    }

    /// The best `limit` hits as items: noise dropped, scored on the file name (`score`) minus
    /// `penalty`, so they rank fairly against other `.match` items.
    public static func items(_ hits: [Hit], query: String, scopes: [String], home: String) -> [Item] {
        let folded = Fold.query(query)
        let words = query.split(whereSeparator: \.isWhitespace).map { Fold.query(String($0)) }
        var scored: [(hit: Hit, name: String, score: Int)] = []
        for hit in hits {
            guard let scope = scopes.first(where: { hit.path.hasPrefix($0 + "/") }),
                !isExcluded(hit.path.dropFirst(scope.count))
            else { continue }
            let name = (hit.path as NSString).lastPathComponent
            guard let score = score(folded, words: words, name: SearchKey(name)) else { continue }
            scored.append((hit, name, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.hit.path < b.hit.path
        }
        return scored.prefix(limit).map { hit, name, score in
            let url = URL(filePath: hit.path, directoryHint: hit.isFolder ? .isDirectory : .notDirectory)
            return Item(
                id: "files:" + hit.path, title: name, subtitle: displayFolder(of: hit.path, home: home),
                icon: .file(url: url), accessory: hit.isFolder ? "Folder" : "File",
                score: Double(score) - penalty, actions: Item.Action.forFile(url))
        }
    }

    /// The shared fuzzy matcher's score for the whole query, which keeps its whole-name bonuses (the
    /// name starts with or is the query); for a query whose words the name has in another order
    /// ("report annual" for "Annual Report.pdf", which Spotlight found by every word), the sum of
    /// each word's own score less one prefix bonus, so a name in the query's order ranks first. Nil
    /// if the name doesn't match.
    static func score(_ query: [UInt32], words: [[UInt32]], name: SearchKey) -> Int? {
        if let score = FuzzyMatcher.score(query, name) { return score }
        guard words.count > 1 else { return nil }
        var total = -FuzzyMatcher.Weight.prefix
        for word in words {
            guard let score = FuzzyMatcher.score(word, name) else { return nil }
            total += score
        }
        return total
    }

    /// The folder shown under a file's name: "~/Documents/Taxes", "iCloud Drive/Notes", "/Volumes/Disk".
    public static func displayFolder(of path: String, home: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if parent == iCloud || parent.hasPrefix(iCloud + "/") {
            return "iCloud Drive" + parent.dropFirst(iCloud.count)
        }
        if parent == home || parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
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
