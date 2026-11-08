import Foundation

extension Item {
    /// What a row is about, sent as an identifier so Wicket derives what it can (docs/extensions.md,
    /// "Subjects"): fields the producer sent win, and derived actions follow the producer's.
    public enum Subject: Sendable, Hashable {
        /// A file or folder, standardized (no `.` or `..`) but named as the producer named it.
        case file(URL)
        /// A web, mail or app link.
        case url(URL)
    }
}

extension Item.Subject {
    /// A `file` subject from the wire: an absolute or `~/` path, or a `file:` URL. Nil for anything else.
    public static func file(parsing value: String, home: URL) -> Item.Subject? {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(filePath: value)
        } else if value == "~" {
            url = home
        } else if value.hasPrefix("~/") {
            url = home.appending(path: String(value.dropFirst(2)))
        } else if let parsed = URL(string: value), parsed.isFileURL,
            parsed.path(percentEncoded: false).hasPrefix("/")
        {
            url = URL(filePath: parsed.path(percentEncoded: false))
        } else {
            return nil
        }
        return .file(url.standardizedFileURL)
    }

    /// A `url` subject from the wire: a URL with a scheme other than `file:` (which is a `file`).
    public static func url(parsing value: String) -> Item.Subject? {
        guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty, !url.isFileURL
        else { return nil }
        return .url(url)
    }

    /// The id a row about this has when the producer sends none: the file's path with symlinks
    /// resolved (so Claude's `/private/tmp/x` and Codex's `/tmp/x` are one row), or the URL. Two
    /// files of the same name never collide.
    public var id: String {
        switch self {
        case .file(let url): "file:" + Self.canonical(url).path(percentEncoded: false)
        case .url(let url): "url:" + url.absoluteString
        }
    }

    /// `url` with symlinks resolved. Of a file that isn't there, its nearest folder that is, so a
    /// deleted file keeps the id it had.
    static func canonical(_ url: URL) -> URL {
        var missing: [String] = []
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)),
            existing.pathComponents.count > 1
        {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
    }

    /// The file's name, else the link's host, else the whole link.
    public var title: String {
        switch self {
        case .file(let url): url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent
        case .url(let url): url.host(percentEncoded: false) ?? url.absoluteString
        }
    }

    /// The folder a file is in (`~`-relative), "Not found" if it isn't there; a link's path, if any.
    public func subtitle(home: URL, exists: Bool) -> String? {
        switch self {
        case .file(let url):
            guard exists else { return "Not found" }
            return Self.display(url.deletingLastPathComponent(), home: home)
        case .url(let url):
            let path = url.path(percentEncoded: false)
            return path.isEmpty || path == "/" ? nil : path
        }
    }

    public var icon: Item.Icon {
        switch self {
        case .file(let url): .file(url: url)
        case .url(let url): .symbol(name: url.scheme?.lowercased() == "mailto" ? "envelope" : "globe")
        }
    }

    /// Open, Reveal in Finder and Copy Path for a file; Open and Copy Link for a link.
    public var actions: [Item.Action] {
        switch self {
        case .file(let url): Item.Action.forFile(url)
        case .url(let url): [.open(url: url), .copy(text: url.absoluteString, title: "Copy Link")]
        }
    }

    /// Where it is, as text: a file's `~`-relative path, or the link.
    public func location(home: URL) -> String {
        switch self {
        case .file(let url): Self.display(url, home: home)
        case .url(let url): url.absoluteString
        }
    }

    /// `url`'s path, with the home folder as `~`.
    static func display(_ url: URL, home: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let homePath = home.standardizedFileURL.path(percentEncoded: false)
        let trimmed = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if path == trimmed || path == trimmed + "/" { return "~" }
        if path.hasPrefix(trimmed + "/") { return "~" + path.dropFirst(trimmed.count) }
        return path
    }
}

extension Item.Action {
    /// The producer's actions, then the derived ones that don't repeat one of them: same kind and
    /// same target (a file's path, a link, a text). A `detail` or `run` is never a repeat.
    static func merged(_ producer: [Item.Action], _ derived: [Item.Action]) -> [Item.Action] {
        let sent = Set(producer.compactMap(\.target))
        return producer + derived.filter { $0.target.map { !sent.contains($0) } ?? true }
    }

    /// What the action acts on, with its kind; nil for actions that carry more than a target.
    private var target: String? {
        switch self {
        case .open(let url, _), .reveal(let url, _):
            "\(kind):" + (url.isFileURL ? url.standardizedFileURL.absoluteString : url.absoluteString)
        case .copy(let text, _), .paste(let text, _): "\(kind):\(text)"
        case .detail, .run: nil
        }
    }
}
