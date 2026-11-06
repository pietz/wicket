import Foundation

/// A provider of root search results. The palette asks every source on each keystroke and ranks all
/// their items together (`RootResults`, `Ranker`); sources choose each item's relevance tier and
/// score. Only the root frame uses sources: a command's own list is the command's business.
@MainActor
public protocol ResultSource {
    /// Prefix of this source's item ids ("apps" gives "apps:/Applications/Safari.app").
    var id: String { get }

    /// Results available right now, from memory. Runs on the main actor on every keystroke, so it
    /// must be fast and never wait on disk, network or another process.
    func instant(_ query: Query) -> [Item]

    /// Slow results for `query`, for sources that search files or talk to extensions. Each element
    /// replaces everything this source returned for the query so far. When the query changes the
    /// palette stops iterating, which terminates the stream: stop the work in `onTermination`.
    func updates(_ query: Query) -> AsyncStream<[Item]>?
}

extension ResultSource {
    public func updates(_ query: Query) -> AsyncStream<[Item]>? { nil }
}
