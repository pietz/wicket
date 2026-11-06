import Foundation
import Observation
import WicketCore

/// What the pill is doing. Only idle exists today; listening and thinking become cases here, each
/// with its own glyph and prompt.
enum PaletteMode {
    case idle

    var symbol: String {
        switch self {
        case .idle: "magnifyingglass"
        }
    }

    var prompt: String {
        switch self {
        case .idle: "Search or run a command"
        }
    }
}

/// The palette's view state around its `PaletteSession` (Core), which owns the frames, the search
/// and the navigation: this adds what only the window needs (focus, the action panel, the card's
/// height) and the usage store.
@MainActor
@Observable
final class PaletteModel {
    static let resultLimit = 50

    let session: PaletteSession
    var top: Frame { session.top }
    /// The top frame's rows; empty for a detail.
    var results: [Item] { top.list?.items ?? [] }
    var selection: Int { top.list?.selection ?? 0 }
    var target: ActionTarget? { top.target }

    var query: String {
        get { session.query }
        set {
            let start = ContinuousClock.now
            session.query = newValue
            logQuery(since: start)
        }
    }
    /// Bumped on every summon so a SwiftUI search field can take focus.
    var focusToken = 0
    /// The action panel (⌘K), when open. One optional, so at most one panel exists.
    var actionMenu: ActionMenu?
    /// ⌘ is held, so rows show their ⌘1 to ⌘9 hints.
    var commandHeld = false
    var mode = PaletteMode.idle
    /// The height of the results card under the pill, 0 while there is none. Set by
    /// `PaletteController`, which sizes the window to match.
    var cardHeight: CGFloat = 0
    var isExpanded: Bool { cardHeight > 0 }
    @ObservationIgnored private var usage: UsageStore
    @ObservationIgnored private let usageURL: URL

    init(sources: [any ResultSource]) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let usageURL = support.appending(path: "Wicket/usage.json")
        self.usageURL = usageURL
        usage = Self.namespaced(UsageStore.load(from: usageURL))
        weak var model: PaletteModel?
        session = PaletteSession(sources: sources, resultLimit: Self.resultLimit) {
            model?.frecency() ?? { _ in 0 }
        }
        model = self
    }

    func moveSelection(by delta: Int) {
        session.moveSelection(by: delta)
    }

    /// Runs the root search again, for when a source's data changed.
    func refresh() {
        let start = ContinuousClock.now
        session.refresh()
        logQuery(since: start)
    }

    /// Answers are computed per query, so a usage boost for them would mean nothing.
    func recordUse(of item: Item) {
        guard item.relevance != .answer else { return }
        usage.record(item.id, now: Date())
        let snapshot = usage
        let url = usageURL
        Task.detached(priority: .utility) { try? snapshot.save(to: url) }
    }

    private func logQuery(since start: ContinuousClock.Instant) {
        guard case .search = top.content, !top.query.isEmpty else { return }
        Perf.log("query (\(top.query.count) chars): \(results.count) results in \(Perf.ms(since: start))")
    }

    private func frecency() -> (String) -> Double {
        let usage = self.usage
        let now = Date()
        return { usage.frecency($0, now: now) }
    }

    /// usage.json from before result sources keyed apps by bare path and Quit as "wicket.quit".
    private static func namespaced(_ store: UsageStore) -> UsageStore {
        let entries = store.entries.map { id, entry in
            let renamed =
                id == "wicket.quit" ? "commands:quit" : id.hasPrefix("/") ? "apps:" + id : id
            return (renamed, entry)
        }
        return UsageStore(entries: Dictionary(entries, uniquingKeysWith: { first, _ in first }))
    }
}
