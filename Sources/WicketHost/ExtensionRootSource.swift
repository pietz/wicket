import Foundation
import WicketCore
import os

/// Root-mode extension commands in the root search. A non-empty query reaches each root command
/// whose `pattern` matches it (every one without a pattern), after `debounce` without a newer query,
/// since every keystroke would otherwise start a run per command. Their items (at most `itemLimit`
/// each) join the root results as they arrive; `Ranker` keeps each command's block in the order it
/// sent. A failure is never shown inline (docs/extensions.md): it is kept in `failures` for the
/// Extensions screen and logged without its text.
@MainActor
public final class ExtensionRootSource: ResultSource {
    public let id = "extensions"
    public static let itemLimit = 10
    /// The last failure of each root command, cleared by its next answer.
    public private(set) var failures: [CommandID: String] = [:]
    private let extensions: Extensions
    private let debounce: Duration

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    public init(_ extensions: Extensions, debounce: Duration = .milliseconds(80)) {
        self.extensions = extensions
        self.debounce = debounce
    }

    /// Extensions are never memory-only.
    public func instant(_ query: Query) -> [Item] { [] }

    public func updates(_ query: Query) -> AsyncStream<[Item]>? {
        let commands = extensions.rootCommands(matching: query.text).map(\.id)
        guard !commands.isEmpty else { return nil }
        let text = query.text
        return AsyncStream { continuation in
            // Cancelling it (a newer query, dismissal) cancels every request in flight.
            let task = Task { [weak self, extensions, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return continuation.finish() }
                var answered: [CommandID: [Item]] = [:]
                await withTaskGroup(of: (CommandID, Result<RunResult, any Error>).self) { group in
                    for command in commands {
                        group.addTask { await (command, Self.ask(extensions, command, text)) }
                    }
                    for await (command, outcome) in group {
                        switch outcome {
                        case .success(let result):
                            answered[command] = Self.items(of: result)
                            self?.failures[command] = nil
                        case .failure(let error):
                            guard !(error is CancellationError) else { continue }
                            self?.record(error, of: command)
                        }
                        continuation.yield(commands.flatMap { answered[$0] ?? [] })
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func ask(_ extensions: Extensions, _ command: CommandID, _ text: String) async
        -> Result<RunResult, any Error>
    {
        do {
            return .success(
                try await extensions.result(of: Invocation(command: command, text: text), kind: .query))
        } catch {
            return .failure(error)
        }
    }

    /// What a root command adds: its answer, or the first `itemLimit` items of its list. Decoding
    /// already refused any other result for a root command.
    static func items(of result: RunResult) -> [Item] {
        switch result {
        case .answer(let item): [item]
        case .list(let items): Array(items.prefix(itemLimit))
        case .detail, .close, .reload: []
        }
    }

    private func record(_ error: any Error, of command: CommandID) {
        failures[command] = String(describing: error)
        Self.logger.error(
            "root command \(CommandRegistry.itemID(for: command), privacy: .public) failed")
    }
}
