import Foundation

// Derived file/link actions and safe link following for content supplied by agents or extensions.

extension Item.Action {
    /// The usual actions for something on disk: open it, show it in Finder, copy its path.
    public static func forFile(_ url: URL) -> [Item.Action] {
        [.open(url: url), .reveal(url: url), .copy(text: url.path, title: "Copy Path")]
    }
}

/// What a file a page links to is, with symlinks resolved, as far as following the link cares.
public struct LinkedFile: Sendable, Hashable {
    /// The file the link reaches once symlinks are resolved.
    public var target: URL
    /// A regular file with execute permission, or a Finder alias (which opens whatever it points to).
    public var isRunnable: Bool

    public init(target: URL, isRunnable: Bool) {
        self.target = target
        self.isRunnable = isRunnable
    }
}

extension Item.Action {
    /// What a click on a link in a page does: web and mail links open; a file (a `file://` URL, an
    /// absolute path or a `~` path, as agents write them) opens, unless it would run something (an
    /// app, a script, an executable, an installer), which is shown in Finder instead, since a page is
    /// agent or extension output that a prompt injection can steer. A missing file still opens, so
    /// the open says it's gone. Nil for any other link (other schemes, relative paths), which isn't
    /// followed. `inspect` says what a file is, nil if there's none.
    public static func following(
        _ link: URL, home: URL, inspect: (URL) -> LinkedFile?
    ) -> Item.Action? {
        switch link.scheme?.lowercased() {
        case "http", "https", "mailto": return .open(url: link)
        case "file", nil: break
        default: return nil
        }
        let path = link.path(percentEncoded: false)
        let file: URL
        if path == "~" || path.hasPrefix("~/") {
            file = home.appending(path: String(path.dropFirst(2))).standardizedFileURL
        } else if path.hasPrefix("/") {
            file = URL(filePath: path).standardizedFileURL
        } else {
            return nil
        }
        guard let found = inspect(file) else { return .open(url: file) }
        let runs =
            found.isRunnable
            || [file, found.target].contains { runnableExtensions.contains($0.pathExtension.lowercased()) }
        return runs ? .reveal(url: file) : .open(url: file)
    }

    /// Kinds of file that opening runs, installs or hands to an interpreter rather than showing.
    static let runnableExtensions: Set<String> = [
        "app", "appex", "action", "workflow", "prefpane", "saver", "qlgenerator", "plugin", "bundle",
        "osax", "kext", "xpc", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "terminal",
        "scpt", "scptd", "applescript", "py", "pl", "rb", "jar", "pkg", "mpkg", "mobileconfig", "shortcut",
        "fileloc", "inetloc", "webloc",
    ]
}
