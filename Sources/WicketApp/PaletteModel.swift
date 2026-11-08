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
    /// What Return, ⌘↩ and ⌘K act on: the top frame's target, with Read Summary among the screen's
    /// actions while its list has more than its top shows.
    var target: ActionTarget? {
        guard var target = top.target else { return nil }
        if let listing = top.listing,
            SummaryLayout.hasMore(
                listing, summaryClipped: listTop?.frame == top.id && listTop?.clipped == true)
        {
            target.screen.append(ReadSummary.action(for: listing))
        }
        return target
    }
    /// The section title above each of the top frame's rows, nil where none goes.
    var headers: [String?] { top.listing?.headerTitles(for: results) ?? [] }

    var query: String {
        get { session.query }
        set {
            let start = ContinuousClock.now
            session.query = newValue
            logQuery(since: start)
        }
    }
    /// The text size of pages (details, Run Agent's answer), from settings.
    var textSize = TextSize.medium
    /// Bumped on every summon so a SwiftUI search field can take focus.
    var focusToken = 0
    /// The action panel (⌘K), when open. One optional, so at most one panel exists.
    var actionMenu: ActionMenu?
    /// ⌘ is held, so rows show their ⌘1 to ⌘9 hints.
    var commandHeld = false
    /// Voice input into the search field; nil in tests that don't use it.
    var voice: VoiceInput?
    /// Whether spoken words have somewhere to go: the root, or a frame waiting for its text (a
    /// follow-up), as `PaletteSession.setSpokenQuery` writes them.
    var takesSpeech: Bool { session.frames.count == 1 || top.awaitsText }
    /// The name of the app a paste types into (frontmost at summon), for "Paste to Mail".
    var pasteTarget: String?
    /// The height of the results card under the pill, 0 while there is none. Set by
    /// `PaletteController`, which sizes the window to match.
    var cardHeight: CGFloat = 0
    var isExpanded: Bool { cardHeight > 0 }
    /// The top frame's page content as last laid out, which sizes its card.
    private var detailMeasure: DetailMeasure?
    /// The height of a list's top (summary and facts) as last laid out, and whether its summary
    /// was clipped.
    private var listTop: (frame: Frame.ID, height: CGFloat, clipped: Bool)?
    /// The height of the top frame's list top; nil before it is laid out.
    var listTopHeight: CGFloat? { listTop?.frame == top.id ? listTop?.height : nil }
    /// What activating an action under an authority runs (`ActionDispatcher.resolve`), so the footer
    /// and the action panel name it; set by `PaletteController`.
    var resolve: (Item.Action, Authority) -> ActionPolicy.Resolution = { action, _ in .perform(action) }
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
    /// ⌘[ goes back a frame (`PaletteSession.back`): the footer says so when there is nothing to run.
    var canGoBack: Bool { session.frames.count > 1 }
    /// A message (`Messages`) shown in the footer for a moment, while the card is up.
    private(set) var toast: Message?
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?
    @ObservationIgnored private var usage: UsageStore
    /// Saves usage.json off the main actor, one snapshot at a time, the newest last.
    @ObservationIgnored private let usageWriter: LatestWriter<UsageStore>

    /// Where usage is kept: Application Support/Wicket/usage.json.
    nonisolated static var defaultUsageURL: URL {
        Edition.current.supportDirectory.appending(path: "usage.json")
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

    /// The list top of `frame` was laid out `height` tall, its summary `clipped` or not.
    func measureListTop(_ height: CGFloat, clipped: Bool, of frame: Frame.ID) {
        guard frame == top.id else { return }
        listTop = (frame, height, clipped)
    }

    /// `action` named as it runs under `authority`.
    func present(_ action: Item.Action, as authority: Authority) -> ActionPresentation {
        ActionPresentation(action, resolved: resolve(action, authority), pasteTarget: pasteTarget)
    }

    /// What Return runs on `target`, for the footer.
    func primaryPresentation(_ target: ActionTarget) -> ActionPresentation? {
        target.actions.first.map { present($0, as: target.authority) }
    }

    /// The title of the screen action ⌘↩ runs on `target`, if it runs one (Follow Up).
    func screenSecondaryTitle(_ target: ActionTarget) -> String? {
        guard case .screen(let index) = target.secondary, target.screen.indices.contains(index) else {
            return nil
        }
        return present(target.screen[index], as: .host).title
    }

    /// The action panel for `target`.
    func actionMenu(for target: ActionTarget) -> ActionMenu {
        ActionMenu(target: target, screenTitle: screenTitle, present: present)
    }

    /// What the screen's group in the action panel is called: "Answer" for an agent's, else the
    /// command whose frame it is (a pushed page's, the one beneath it).
    private var screenTitle: String {
        for frame in session.frames.reversed() {
            guard case .screen(let screen) = frame.content, let run = screen.run else { continue }
            return screen.context.authority == .agent ? "Answer" : run.command.title
        }
        return "Page"
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
