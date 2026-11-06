import Foundation
import Observation

/// The palette's session: a stack of frames with the root search at the bottom, and the work each
/// frame started. The app renders the top frame and forwards the user's intents here.
///
/// Each keystroke starts a new generation of the top frame. In the root frame that collects every
/// source's instant results synchronously, then applies slow updates as they arrive. Work results
/// are applied only while their frame is still on the stack at the same generation, and work is
/// cancelled when its frame's query changes, when the frame is popped and when the palette is
/// dismissed. An empty root query asks no source: the palette opens as the bare pill.
@MainActor
@Observable
public final class PaletteSession {
    /// Bottom first; never empty, and only the bottom frame is the root search.
    public private(set) var frames: [Frame]
    @ObservationIgnored private let sources: [any ResultSource]
    @ObservationIgnored private let frecency: () -> (String) -> Double
    @ObservationIgnored private var work: [Frame.ID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var lastID = 0

    /// What Escape did, so the app knows when to hide.
    public enum EscapeOutcome: Sendable {
        case clearedText, popped, hide
    }

    /// `frecency` gives the usage scores as of now, read at each ranking.
    public init(
        sources: [any ResultSource], resultLimit: Int = .max,
        frecency: @escaping () -> (String) -> Double = { { _ in 0 } }
    ) {
        self.sources = sources
        self.frecency = frecency
        frames = [Frame(id: 0, content: .search(RootResults(limit: resultLimit)))]
    }

    public var top: Frame { frames[frames.count - 1] }

    /// The search field's text: the top frame's query.
    public var query: String {
        get { top.query }
        set { setQuery(newValue) }
    }

    public func setQuery(_ text: String) {
        let index = frames.count - 1
        guard frames[index].query != text else { return }
        frames[index].query = text
        start(index)
    }

    /// Runs the root search again with the same text, for when a source's data changed. The
    /// selection stays on its item.
    public func refresh() {
        start(0)
    }

    /// Runs the top frame again with the same text, for a `reload` outcome. Only the root search has
    /// work to redo until command frames keep their invocation (refactor step 6).
    public func reload() {
        start(frames.count - 1)
    }

    public func moveSelection(by delta: Int) {
        frames[frames.count - 1].moveSelection(by: delta)
    }

    public func push(_ detail: Detail) {
        lastID += 1
        frames.append(Frame(id: lastID, content: .detail(detail)))
    }

    /// Escape clears the text, else pops the top frame, else asks to hide.
    public func escape() -> EscapeOutcome {
        if !top.query.isEmpty {
            setQuery("")
            return .clearedText
        }
        guard frames.count > 1 else { return .hide }
        let popped = frames.removeLast()
        cancel(popped.id)
        return .popped
    }

    /// Back to an empty root search with no work running, for when the palette is dismissed.
    public func reset() {
        for frame in frames.dropFirst() { cancel(frame.id) }
        frames.removeSubrange(1...)
        frames[0].query = ""
        start(0)
    }

    // MARK: Work

    /// Starts a new generation of the frame at `index`, cancelling the previous one's work.
    private func start(_ index: Int) {
        let id = frames[index].id
        cancel(id)
        frames[index].generation += 1
        frames[index].pending = 0
        guard case .search(var results) = frames[index].content else { return }

        let query = Query(text: frames[index].query, revision: frames[index].generation)
        let usage = frecency()
        guard !query.text.isEmpty else {
            results.start(query, results: [:], usage: usage)
            frames[index].content = .search(results)
            return
        }
        var instant: [String: [Item]] = [:]
        for source in sources { instant[source.id] = source.instant(query) }
        results.start(query, results: instant, usage: usage)
        frames[index].content = .search(results)

        var tasks: [Task<Void, Never>] = []
        for source in sources {
            guard let stream = source.updates(query) else { continue }
            let source = source.id
            let ticket = Ticket(frame: id, generation: query.revision)
            tasks.append(
                Task { [weak self] in
                    for await items in stream {
                        guard let self else { return }
                        apply(ticket) { frame in
                            guard case .search(var results) = frame.content else { return }
                            results.update(source, items: items, revision: query.revision, usage: frecency())
                            frame.content = .search(results)
                        }
                    }
                    self?.apply(ticket) { $0.pending -= 1 }
                })
        }
        frames[index].pending = tasks.count
        work[id] = tasks
    }

    /// Identifies the frame and generation a piece of work belongs to.
    private struct Ticket {
        let frame: Frame.ID
        let generation: Int
    }

    /// Applies `change` if the ticket's frame is still on the stack at the same generation.
    private func apply(_ ticket: Ticket, _ change: (inout Frame) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == ticket.frame }),
            frames[index].generation == ticket.generation
        else { return }
        change(&frames[index])
    }

    private func cancel(_ frame: Frame.ID) {
        for task in work.removeValue(forKey: frame) ?? [] { task.cancel() }
    }
}
