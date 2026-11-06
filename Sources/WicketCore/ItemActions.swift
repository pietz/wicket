import Foundation

extension Item.Action {
    /// The usual actions for something on disk: open it, show it in Finder, copy its path.
    public static func forFile(_ url: URL) -> [Item.Action] {
        [.open(url: url), .reveal(url: url), .copy(text: url.path, title: "Copy Path")]
    }
}
