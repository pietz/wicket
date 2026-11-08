import Foundation
import Observation
import WicketCore

/// The palette's view state around its `PaletteSession` (Core), which owns the frames, the search
/// and the navigation: this adds what only the window needs (focus, the action panel, the card's
/// height) and the usage store.
@MainActor
@Observable
final class PaletteModel {
    static let resultLimit = 50

    let session: PaletteSession
    var top: Frame { session.top }
    /// The top frame's rows; empty for a page.
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
    /// Voice input into the search field; nil in tests that don't use it.
    var voice: VoiceInput?
    /// The name of the app a paste types into (frontmost at summon), for "Paste to Mail".
    var pasteTarget: String?
    /// The height of the results card under the pill, 0 while there is none. Set by
    /// `PaletteController`, which sizes the window to match.
    var cardHeight: CGFloat = 0
    var isExpanded: Bool { cardHeight > 0 }
    /// The top frame's page content as last laid out, which sizes its card.
    private var detailMeasure: DetailMeasure?
    /// The height the top frame's page content needs; nil for rows, or before it is laid out.
    var detailHeight: CGFloat? {
        detailMeasure?.height(of: top.id, isLoading: top.isLoading).map { CGFloat($0) }
    }
    /// A command is running for what's on screen: one an action is opening, or the top frame's run
    /// (the root's slow sources don't count). The pill shows a spinner.
    var isBusy: Bool {
        if session.opening != nil { return true }
        if case .screen = top.content { return top.isLoading }
        return false
    }
    /// What Escape does from here, for the footer when there is nothing to run: clear the text, else
    /// go back a frame (`PaletteSession.escape`); hiding needs no hint.
    var escapeHint: String? {
        if !top.query.isEmpty { return "Clear" }
        return session.frames.count > 1 ? "Back" : nil
    }
    /// A message (`Messages`) shown in the footer for a moment, while the card is up.
    private(set) var toast: Message?
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?
    @ObservationIgnored private var usage: UsageStore
    /// Saves usage.json off the main actor, one snapshot at a time, the newest last.
    @ObservationIgnored private let usageWriter: LatestWriter<UsageStore>

    /// Where usage is kept: Application Support/Wicket/usage.json.
    nonisolated static var defaultUsageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wicket/usage.json")
    }

    init(
        sources: [any ResultSource], runner: (any CommandRunner)? = nil, registry: CommandRegistry? = nil,
        messages: Messages = Messages(), usageURL: URL = defaultUsageURL
    ) {
        usageWriter = LatestWriter { try? $0.save(to: usageURL) }
        usage = Self.namespaced(UsageStore.load(from: usageURL))
        weak var model: PaletteModel?
        session = PaletteSession(
            sources: sources, resultLimit: Self.resultLimit,
            frecency: { model?.frecency() ?? { _ in 0 } }, runner: runner, registry: registry,
            messages: messages)
        model = self
    }

    /// The detail view of `frame` was laid out with its content `height` tall.
    func measureDetail(_ height: CGFloat, of frame: Frame.ID) {
        guard frame == top.id else { return }
        if detailMeasure == nil {
            detailMeasure = DetailMeasure(frame: frame, height: Double(height))
        } else {
            detailMeasure?.record(Double(height), frame: frame, isLoading: top.isLoading)
        }
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

    /// Shows `message` in the footer for two seconds; nil clears it at once.
    func showToast(_ message: Message?) {
        toast = message
        toastExpiry?.cancel()
        guard message != nil else { return }
        toastExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Answers are computed per query and fallback rows are offered for any query, so a usage boost
    /// for them would mean nothing.
    func recordUse(of item: Item) {
        guard item.relevance != .answer, item.relevance != .fallback else { return }
        usage.record(item.id, now: Date())
        usageWriter.submit(usage)
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
