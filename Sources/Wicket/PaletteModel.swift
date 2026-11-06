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

/// The palette's session: the query, every source's results for it, and the selection.
///
/// Each keystroke starts a new query revision, collects every source's instant results
/// synchronously, then applies slow updates as they arrive if their revision is still current.
/// An empty query asks no source: the palette opens as the bare pill.
@MainActor
@Observable
final class PaletteModel {
    static let resultLimit = 50

    private(set) var list = ResultList(limit: resultLimit)
    var results: [Item] { list.items }
    var selection: Int { list.selection }
    var selectedItem: Item? { list.selectedItem }

    var query = "" { didSet { if query != oldValue { refresh() } } }
    /// Bumped on every summon so a SwiftUI search field can take focus.
    var focusToken = 0
    /// The action panel (⌘K), when open. One optional, so at most one panel exists.
    var actionMenu: ActionMenu?
    /// ⌘ is held, so rows show their ⌘1 to ⌘9 hints.
    var commandHeld = false
    var mode = PaletteMode.idle
    /// The results card under the pill is shown. Set by `PaletteController`, which sizes the window
    /// to match.
    var isExpanded = false
    @ObservationIgnored private let sources: [any ResultSource]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var updates: [Task<Void, Never>] = []
    @ObservationIgnored private var usage: UsageStore
    @ObservationIgnored private let usageURL: URL

    init(sources: [any ResultSource]) {
        self.sources = sources
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        usageURL = support.appending(path: "Wicket/usage.json")
        usage = Self.namespaced(UsageStore.load(from: usageURL))
        refresh()
    }

    func moveSelection(by delta: Int) {
        list.moveSelection(by: delta)
    }

    /// Answers are computed per query, so a usage boost for them would mean nothing.
    func recordUse(of item: Item) {
        guard item.relevance != .answer else { return }
        usage.record(item.id, now: Date())
        let snapshot = usage
        let url = usageURL
        Task.detached(priority: .utility) { try? snapshot.save(to: url) }
    }

    /// Runs the current query again on every source, for when a source's data changed.
    func refresh() {
        let start = ContinuousClock.now
        revision += 1
        let query = Query(text: query, revision: revision)
        for task in updates { task.cancel() }
        updates = []

        guard !query.text.isEmpty else {
            list.start(query, results: [:], usage: frecency())
            return
        }
        var instant: [String: [Item]] = [:]
        for source in sources { instant[source.id] = source.instant(query) }
        list.start(query, results: instant, usage: frecency())
        Perf.log("query (\(query.text.count) chars): \(list.items.count) results in \(Perf.ms(since: start))")

        for source in sources {
            guard let stream = source.updates(query) else { continue }
            let id = source.id
            updates.append(
                Task { [weak self] in
                    for await items in stream {
                        guard let self else { return }
                        list.update(id, items: items, revision: query.revision, usage: frecency())
                    }
                })
        }
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
