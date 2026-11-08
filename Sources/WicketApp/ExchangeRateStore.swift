import Foundation
import WicketCore
import os

/// The calculator's exchange rates: the ECB daily feed, cached as the raw XML in
/// `~/Library/Caches/Wicket/` and fetched again only once the cached copy is a day old.
///
/// Offline, the last cached rates keep answering; results carry their day so the UI can show it.
/// The session is ephemeral with no URL cache, so the file here is the only copy on disk.
@MainActor
final class ExchangeRateStore {
    private(set) var rates: ExchangeRates?
    var onChange: (() -> Void)?

    nonisolated static let refreshInterval: TimeInterval = 24 * 3600
    nonisolated static let retryInterval: TimeInterval = 3600
    nonisolated static let cacheURL = URL.cachesDirectory.appending(path: "Wicket/eurofxref-daily.xml")

    private static let logger = Logger(subsystem: "app.wicket", category: "rates")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// Loads the cache, then keeps the rates fresh: a fetch when the cache is a day old, and a
    /// retry every hour while fetching fails. Called once, at launch.
    func start() {
        let cachedAt = loadCache()
        Task {
            var fetchedAt = cachedAt
            while !Task.isCancelled {
                let due = fetchedAt?.addingTimeInterval(Self.refreshInterval) ?? .distantPast
                if due > .now {
                    try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow))
                } else if await fetch() {
                    fetchedAt = .now
                } else {
                    try? await Task.sleep(for: .seconds(Self.retryInterval))
                }
            }
        }
    }

    /// Reads the cached feed; returns when it was fetched (the file's modification date).
    private func loadCache() -> Date? {
        guard let data = try? Data(contentsOf: Self.cacheURL),
            let cached = try? ECBFeed.parse(data)
        else { return nil }
        update(cached)
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private func fetch() async -> Bool {
        do {
            let (data, response) = try await session.data(from: ECBFeed.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let fresh = try ECBFeed.parse(data)  // Only valid feeds replace the cache.
            try FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.cacheURL, options: .atomic)
            Self.logger.notice("fetched ECB rates of \(fresh.dayString, privacy: .public)")
            update(fresh)
            return true
        } catch {
            Self.logger.error("ECB rates fetch failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func update(_ new: ExchangeRates) {
        guard new != rates else { return }
        rates = new
        onChange?()
    }
}
