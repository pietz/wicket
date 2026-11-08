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
    /// What Return, ⌘↩ and ⌘K act on: the top frame's target, with Load Images among the screen's
    /// actions while its page holds images that wait for online content.
    var target: ActionTarget? {
        guard var target = top.target else { return nil }
        if !loadsOnlineContent, blockedImages?.frame == top.id, blockedImages?.count ?? 0 > 0 {
            target.screen.append(.run(command: .loadImages, title: "Load Images"))
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
    /// Whether pages load images from the web ("Show online content"), from settings.
    var showsOnlineContent = true
    /// Pages whose images the user loaded with Load Images while online content is off.
    private var imagesLoaded: Set<Frame.ID> = []
    /// How many images the top frame's page holds back while online content is off.
    private var blockedImages: (frame: Frame.ID, count: Int)?
    /// Whether the top frame's page loads its web images.
    var loadsOnlineContent: Bool { showsOnlineContent || imagesLoaded.contains(top.id) }
    /// The latest press of the arrows, for the list or page to bring into view what it selected or,
    /// when it selected nothing new, to scroll.
    private(set) var navigation: Navigation?
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
    /// The height of a list's summary as last laid out.
    private var listTop: (frame: Frame.ID, height: CGFloat)?
    /// The height of the top frame's list top; nil before it is laid out.
    var listTopHeight: CGFloat? { listTop?.frame == top.id ? listTop?.height : nil }
    /// What activating an action under an authority runs (`ActionDispatcher.resolve`), so the footer
    /// and the action panel name it; set by `PaletteController`.
    var resolve: (Item.Action, Authority) -> ActionPolicy.Resolution = { action, _ in .perform(action) }
    /// The height the top frame's page content needs; nil for rows, or before it is laid out.
    var detailHeight: CGFloat? {
        detailMeasure?.height(of: top.id, isLoading: top.isLoading).map { CGFloat($0) }
    }
    /// The top frame's command is running (the root's slow sources don't count). The pill spins.
    var isBusy: Bool { top.run != nil && top.isLoading }
    /// Escape goes back a frame (`PaletteSession.back`): the footer says so when there is nothing to run.
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

    /// The list summary of `frame` was laid out `height` tall.
    func measureListTop(_ height: CGFloat, of frame: Frame.ID) {
        guard frame == top.id else { return }
        listTop = (frame, height)
    }

    /// The page of `frame` holds back `count` web images while online content is off.
    func blockImages(_ count: Int, of frame: Frame.ID) {
        guard frame == top.id, blockedImages?.frame != frame || blockedImages?.count != count else { return }
        blockedImages = (frame, count)
    }

    /// Load Images: the top frame's page loads its web images, this once.
    func loadImages() {
        imagesLoaded.insert(top.id)
    }

    /// Forgets what the last summon's pages loaded, for when the palette is dismissed.
    func forgetPages() {
        imagesLoaded = []
        blockedImages = nil
        navigation = nil
    }

    /// `action` named as it runs under `authority`.
    func present(_ action: Item.Action, as authority: Authority) -> ActionPresentation {
        ActionPresentation(action, resolved: resolve(action, authority), pasteTarget: pasteTarget)
    }

    /// What Return runs on `target`, for the footer.
    func primaryPresentation(_ target: ActionTarget) -> ActionPresentation? {
        target.action(at: target.primary).map { present($0.action, as: $0.authority) }
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

    /// The arrows: move the selection, and say so (`navigation`), whether it moved or not: a list
    /// reveals its selected row, and a page whose selection stayed (no targets, or past the last)
    /// scrolls its prose instead.
    func moveSelection(by delta: Int) {
        let before = top.list?.hasSelection == true ? top.list?.selectedItem?.id : nil
        session.moveSelection(by: delta)
        let after = top.list?.hasSelection == true ? top.list?.selectedItem?.id : nil
        navigation = Navigation(serial: (navigation?.serial ?? 0) + 1, delta: delta, moved: before != after)
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
