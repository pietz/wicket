import Foundation

extension Item.Action {
    private static let revealPrefix = "reveal:"

    /// Shows a file, folder or app selected in a Finder window.
    ///
    /// Carried as a built-in command whose id holds the path, because `Item.Action` has no case for
    /// it yet; when it gains one, this function becomes that case and call sites stay the same.
    public static func reveal(_ url: URL) -> Item.Action {
        .command(id: revealPrefix + url.path)
    }

    /// The file a `reveal` action shows, or nil for any other action.
    public var revealedURL: URL? {
        guard case .command(let id) = self, id.hasPrefix(Self.revealPrefix) else { return nil }
        return URL(filePath: String(id.dropFirst(Self.revealPrefix.count)))
    }

    /// The usual actions for something on disk: open it, show it in Finder, copy its path.
    public static func forFile(_ url: URL) -> [Item.Action] {
        [.open(url: url), .reveal(url), .copy(text: url.path)]
    }
}
