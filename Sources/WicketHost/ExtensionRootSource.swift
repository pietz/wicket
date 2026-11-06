import Foundation
import WicketCore

/// Root-mode extension commands in the root search. A non-empty query reaches each root command
/// whose `pattern` matches it (every one without a pattern), after `debounce` without a newer query,
/// since every keystroke would otherwise start a run per command. Their items (at most `itemLimit`
/// each) join the root results as they arrive; `Ranker` keeps each command's block in the order it
/// sent. A failure is never shown inline (docs/extensions.md): `Extensions` records it in its
/// diagnostics for the Extensions screen, like any failed run.
@MainActor
public final class ExtensionRootSource: ResultSource {
    public let id = "extensions"
    public static let itemLimit = 10
    private let extensions: Extensions
    private let debounce: Duration

    public init(_ extensions: Extensions, debounce: Duration = .milliseconds(80)) {
        self.extensions = extensions
        self.debounce = debounce
    }

    /// Extensions are never memory-only.
    public func instant(_ query: Query) -> [Item] { [] }

    public func updates(_ query: Query) -> AsyncStream<[Item]>? {
        let matching = extensions.rootCommands(matching: query.text)
        guard !matching.isEmpty else { return nil }
        let commands = matching.map(\.id)
        // Root queries are searches, so their manifest translation makes them safe to repeat.
        let retry = Dictionary(matching.map { ($0.id, $0.retry) }, uniquingKeysWith: { a, _ in a })
        let text = query.text
        return AsyncStream { continuation in
            // Cancelling it (a newer query, dismissal) cancels every request in flight.
            let task = Task { [extensions, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return continuation.finish() }
                var answered: [CommandID: [Item]] = [:]
                await withTaskGroup(of: (CommandID, Result<RunResult, any Error>).self) { group in
                    for command in commands {
                        group.addTask {
                            await (command, Self.ask(extensions, command, text, retry[command] ?? .never))
                        }
                    }
                    for await (command, outcome) in group {
                        switch outcome {
                        case .success(let result):
                            answered[command] = Self.items(of: result)
                        case .failure:
                            continue
                        }
                        continuation.yield(commands.flatMap { answered[$0] ?? [] })
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func ask(
        _ extensions: Extensions, _ command: CommandID, _ text: String, _ retry: RetryPolicy
    ) async -> Result<RunResult, any Error> {
        do {
            return .success(
                try await extensions.result(of: Invocation(command: command, text: text), retry: retry))
        } catch {
            return .failure(error)
        }
    }

    /// What a root command adds: its answer, or the first `itemLimit` items of its list. Decoding
    /// already refused any other result for a root command.
    static func items(of result: RunResult) -> [Item] {
        guard case .show(let screen) = result, let items = screen.items else { return [] }
        return Array(items.prefix(itemLimit))
    }
}
