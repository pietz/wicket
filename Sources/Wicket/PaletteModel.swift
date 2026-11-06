import AppKit
import Observation
import WicketCore

struct PaletteItem: Identifiable, Equatable {
    enum Icon: Equatable {
        case file(URL)
        case symbol(String)
    }

    enum Action: Equatable {
        case openApp(URL)
        case quit
    }

    let id: String
    let title: String
    let accessory: String
    let icon: Icon
    let action: Action
}

/// The palette's state: everything searchable, the current query and its ranked results.
@MainActor
@Observable
final class PaletteModel {
    static let resultLimit = 50

    private(set) var results: [PaletteItem] = []
    var selection = 0

    var query = "" { didSet { if query != oldValue { refresh() } } }
    /// Bumped on every summon so a SwiftUI search field can take focus.
    var focusToken = 0
    @ObservationIgnored private var items: [PaletteItem] = []
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var usage: UsageStore
    @ObservationIgnored private let usageURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        usageURL = support.appending(path: "Wicket/usage.json")
        usage = UsageStore.load(from: usageURL)
    }

    func setItems(_ items: [PaletteItem], alternates: [String: [String]]) {
        self.items = items
        candidates = items.map { Candidate(id: $0.id, title: $0.title, alternates: alternates[$0.id] ?? []) }
        refresh()
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    var selectedItem: PaletteItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func recordUse(of item: PaletteItem) {
        usage.record(item.id, now: Date())
        let snapshot = usage
        let url = usageURL
        Task.detached(priority: .utility) { try? snapshot.save(to: url) }
    }

    private func refresh() {
        let start = ContinuousClock.now
        let now = Date()
        let usage = self.usage
        let ranked = Ranker.rank(
            query: query, candidates: candidates, usage: { usage.frecency($0, now: now) },
            limit: Self.resultLimit)
        results = ranked.map { items[$0] }
        selection = 0
        if !query.isEmpty {
            Perf.log("rank \"\(query)\": \(ranked.count) results in \(Perf.ms(since: start))")
        }
    }
}
