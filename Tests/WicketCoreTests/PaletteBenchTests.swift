import Foundation
import Testing

@testable import WicketCore

// The session's hot paths, timed: a root keystroke over 500 indexed items, and a command frame's
// push to its first list of 200 rows. Timing is noisy beside other tests, so it runs only when asked:
// `WICKET_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PaletteBench`.

@MainActor
private final class IndexSource: ResultSource {
    let id = "bench"
    private let index: SearchIndex

    init() {
        let words = [
            "safari", "code", "notes", "mail", "music", "photos", "terminal", "finder", "maps", "xcode",
        ]
        let items = (0..<500).map {
            Item(
                id: "bench:\($0)", title: "\(words[$0 % 10]) \(words[($0 / 10) % 10]) \($0)",
                icon: .symbol(name: "doc"), actions: [])
        }
        index = SearchIndex(items.map { ($0, []) })
    }

    func instant(_ query: Query) -> [Item] { index.search(query.text) }
}

@MainActor
private final class ListRunner: CommandRunner {
    let rows = (0..<200).map {
        Item(id: "ext:b/l:\($0)", title: "Row \($0)", icon: .symbol(name: "doc"), actions: [])
    }

    func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        continuation.yield(.show(.list(Listing(rows)), .host))
        continuation.finish()
        return stream
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WICKET_BENCH"] == "1"))
struct PaletteBench {
    @Test func rootKeystroke() {
        let session = PaletteSession(sources: [IndexSource()], resultLimit: 50)
        let queries = ["s", "sa", "saf", "safa", "safar", "safari", "c", "co", "cod", "code"]
        let start = ContinuousClock.now
        for _ in 0..<200 {
            for query in queries { session.query = query }
        }
        print("PaletteBench root keystroke: \((ContinuousClock.now - start) / 2000)")
    }

    @Test func framePush() async {
        let command = RegisteredCommand(
            id: .extension("b", "l"), title: "Bench List", icon: .symbol(name: "doc"), keyword: "bl")
        let registry = CommandRegistry(builtins: [])
        registry.setExtensionCommands([command])
        let session = PaletteSession(sources: [], runner: ListRunner(), registry: registry)
        var total = Duration.zero
        for _ in 0..<200 {
            let start = ContinuousClock.now
            session.open(CommandRun(command, .invoked))
            while session.top.list?.items.count != 200 { await Task.yield() }
            total += ContinuousClock.now - start
            session.reset()
        }
        print("PaletteBench frame push to first content: \(total / 200)")
    }
}
