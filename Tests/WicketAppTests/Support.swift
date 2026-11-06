import Foundation
import WicketCore

func item(_ title: String, relevance: Item.Relevance = .match, actions: [Item.Action] = []) -> Item {
    Item(
        id: "test:" + title, title: title, icon: .symbol(name: "doc"), relevance: relevance, actions: actions)
}

/// A root source answering every non-empty query with the same items.
@MainActor
final class StaticSource: ResultSource {
    let id: String
    var items: [Item]

    init(_ id: String, items: [Item]) {
        self.id = id
        self.items = items
    }

    func instant(_ query: Query) -> [Item] { items }
}

/// A runner whose runs the test feeds: each run's continuation is kept by command, and a run whose
/// iteration ended (a dropped frame, a reset) is recorded as cancelled.
@MainActor
final class FakeRunner: CommandRunner {
    private(set) var runs: [CommandID: AsyncThrowingStream<RunResult, any Error>.Continuation] = [:]
    private(set) var cancelled: Set<CommandID> = []
    /// How many runs each command has had.
    private(set) var count: [CommandID: Int] = [:]

    func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let id = invocation.command
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancelled.insert(id) }
        }
        runs[id] = continuation
        count[id, default: 0] += 1
        return stream
    }
}

/// Lets the main actor's tasks run until `condition` holds; false if it never does.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

func command(_ name: String, mode: Manifest.Command.Mode = .once) -> RegisteredCommand {
    RegisteredCommand(
        id: .extension("test", name), title: name.capitalized, icon: .symbol(name: "doc"), mode: mode)
}
