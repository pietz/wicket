import CoreServices
import Foundation
import WicketCore

/// Searches of the Spotlight index through the MDQuery C API.
///
/// MDQuery rather than `NSMetadataQuery`: it caps results inside Spotlight (`MDQuerySetMaxCount`),
/// runs and notifies on our own serial queue instead of a run loop, and stops synchronously.
enum Spotlight {
    /// Items matching `predicate` under `scopes`, at most `limit`. Each element holds every hit
    /// gathered so far, and the stream finishes when gathering does. Terminating it stops the query.
    static func hits(matching predicate: String, in scopes: [String], limit: Int) -> AsyncStream<
        [FileSearch.Hit]
    > {
        AsyncStream { continuation in
            let search = Search(continuation: continuation)
            continuation.onTermination = { _ in search.stop() }
            search.start(predicate, scopes: scopes, limit: limit)
        }
    }
}

/// One running query. Its state is only touched on `queue`, where MDQuery also posts its
/// notifications, which is what makes the unchecked `Sendable` sound.
private final class Search: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "app.wicket.spotlight", qos: .userInitiated)

    private let continuation: AsyncStream<[FileSearch.Hit]>.Continuation
    private var query: MDQuery?
    private var observers: [any NSObjectProtocol] = []

    init(continuation: AsyncStream<[FileSearch.Hit]>.Continuation) {
        self.continuation = continuation
    }

    func start(_ predicate: String, scopes: [String], limit: Int) {
        Self.queue.async { [self] in
            guard
                let query = MDQueryCreate(
                    kCFAllocatorDefault, predicate as CFString, [kMDItemContentType] as CFArray, nil)
            else {
                continuation.finish()
                return
            }
            self.query = query
            MDQuerySetSearchScope(query, scopes as CFArray, 0)
            MDQuerySetMaxCount(query, limit)
            MDQuerySetDispatchQueue(query, Self.queue)
            for (name, final) in [
                (kMDQueryProgressNotification, false), (kMDQueryDidFinishNotification, true),
            ] {
                let name = Notification.Name(name! as String)
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: query, queue: nil) {
                        [self] _ in
                        publish(final: final)
                    })
            }
            // No kMDQueryWantsUpdates: gather once, never watch for changes.
            if !MDQueryExecute(query, 0) { continuation.finish() }
        }
    }

    func stop() {
        Self.queue.async { [self] in
            guard let query else { return }
            MDQueryStop(query)
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            self.query = nil
        }
    }

    private func publish(final: Bool) {
        guard let query else { return }
        let hits = (0..<MDQueryGetResultCount(query)).compactMap { index -> FileSearch.Hit? in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            // Read from the value list Spotlight gathered with the results: copying it per item
            // costs an IPC round trip each, about 0.4 ms.
            let type = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemContentType, index).map {
                Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
            }
            return FileSearch.Hit(path: path, isFolder: type == "public.folder")
        }
        continuation.yield(hits)
        if final { continuation.finish() }
    }
}
