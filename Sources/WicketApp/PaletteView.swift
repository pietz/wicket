import AppKit
import SwiftUI
import WicketCore

// The palette's SwiftUI shell, shared sizing metrics, result rows, footer and action panel.

/// Which field has the keyboard: the search field (the one with this `fieldID`), or the action
/// panel's filter while it is open.
enum PaletteFocus: Hashable {
    case search(String)
    case actions
}

/// The palette's sizes. The window is the visible shapes plus a transparent `margin`, where the
/// glass draws its rim. The width is a setting (`paletteWidth`); the content follows the window's.
@MainActor
enum PaletteMetrics {
    static let pillHeight: CGFloat = 56
    static let gap: CGFloat = 8
    /// The tallest card of plain rows, and of a page: exactly eight whole rows above the divider and
    /// footer, so no row is ever cut in half at rest. A list's summary, its section titles and an
    /// answer on top make its card taller by their height (`cardHeight`).
    static let maxCardHeight: CGFloat =
        CGFloat(maxRows) * (rowHeight + rowSpacing) - rowSpacing + 2 * rowInset + 1 + FooterBar.height
    static let cardRadius: CGFloat = 22
    /// Inset of the rows from the card's edge.
    static let rowInset: CGFloat = 10
    /// The selection's corner radius: the card's minus the inset, so every highlight is concentric
    /// with the card by construction and the same on every row (Apple's guidance for nested shapes).
    static let rowRadius: CGFloat = cardRadius - rowInset
    static let rowHeight: CGFloat = 40
    /// An answer at the top, such as a calculation, shown large.
    static let answerRowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 2
    static let margin: CGFloat = 40

    /// The card for `frame`, and while the action panel is open at least tall enough for it. A
    /// compact frame has none. A list's card is computed: its summary (as measured: `listTop`, up to
    /// `maxListTop`), then whole rows, at most `maxRows` (an answer and seven), with the section titles
    /// above them; more scroll. A screen without rows (a page) fits its content as measured
    /// (`detailHeight`), up to `maxCardHeight`, since markdown wraps. An empty list shows one row
    /// saying so. Nil, keep the card as it is, while a command frame waits for its first content, a
    /// page or a list's top for its first measurement, or the root search for its slow sources with
    /// nothing found yet (so typing never flashes "No Results").
    static func cardHeight(
        for frame: Frame, actionMenu: ActionMenu?, detailHeight: CGFloat?, listTop: CGFloat? = nil
    ) -> CGFloat? {
        if frame.isCompact { return 0 }
        if frame.isMeasured { return detailHeight.map { card(content: $0, actionMenu: actionMenu) } }
        guard let results = frame.list?.items else { return nil }
        if case .search = frame.content, results.isEmpty, frame.isLoading { return nil }
        var top: CGFloat = 0
        var headers: [Bool] = []
        if let listing = frame.listing {
            if listing.summary != nil {
                guard let listTop else { return nil }
                top = min(listTop, maxListTop)
            }
            headers = listing.headerTitles(for: results).map { $0 != nil }
        }
        let prominent = results.first.map { ResultRow.isProminent($0, at: 0) } ?? false
        let content = top + rowsHeight(count: results.count, prominentFirst: prominent, headers: headers)
        return card(
            content: content, actionMenu: actionMenu, cap: max(maxCardHeight, content + 1 + FooterBar.height))
    }

    /// The most rows a card shows whole; more scroll.
    static let maxRows = 8
    /// The most a list's summary adds to its card: four rows' worth. A taller one scrolls with the
    /// rows, so the card never outgrows the screen for a summary.
    static let maxListTop: CGFloat = 4 * (rowHeight + rowSpacing)
    /// A section's title above its first row.
    static let sectionHeaderHeight: CGFloat = 24

    /// The rows' part of a list's card: its first `maxRows` rows (one saying "No Results" for none),
    /// taller by an answer's extra height if one is first, with the section titles among them
    /// (`headers`, one per row: whether a title is drawn above it), and the inset around them.
    static func rowsHeight(count: Int, prominentFirst: Bool, headers: [Bool]) -> CGFloat {
        let shown = min(max(count, 1), maxRows)
        var height = CGFloat(shown) * (rowHeight + rowSpacing) - rowSpacing + 2 * rowInset
        if prominentFirst, count > 0 { height += answerRowHeight - rowHeight }
        height += CGFloat(headers.prefix(shown).filter { $0 }.count) * sectionHeaderHeight
        return height
    }

    /// The card of a page or a list with a top before its content is laid out, when no card is up to
    /// keep: the view must be on screen to be measured, so it opens this small and grows to fit.
    static let unmeasuredHeight = rowHeight + 1 + FooterBar.height

    /// The card for `content` above the divider and footer, up to `cap`.
    private static func card(content: CGFloat, actionMenu: ActionMenu?, cap: CGFloat = maxCardHeight)
        -> CGFloat
    {
        let menu = actionMenu.map { ActionPanel.height(rows: $0.lineCount) + ActionPanel.clearance } ?? 0
        return min(max((content + 1 + FooterBar.height).rounded(.up), menu), cap)
    }

    /// The window for a card of `cardHeight` (0 for just the pill).
    static func windowSize(width: CGFloat, cardHeight: CGFloat) -> NSSize {
        let content = cardHeight > 0 ? pillHeight + gap + cardHeight : pillHeight
        return NSSize(width: width + 2 * margin, height: content + 2 * margin)
    }
}

/// The palette: a Liquid Glass pill holding the search field and, while there is something to show,
/// a glass card under it with the top frame (the results, or a detail) and the footer, with the
/// action panel (⌘K) over them. The
/// glass shapes sit in one container, so the card morphs out of the pill; the content is layered
/// above the container, where a morph can't smear it.
///
/// Chords (⌘K, ⌘↩, ⌘1 to ⌘9, ⌘L, ⌃N, ⌃P) are handled by `PalettePanel` before these fields see them;
/// plain keys are handled here, by whichever field has focus.
struct PaletteRootView: View {
    @Bindable var model: PaletteModel
    /// Runs the action at a position in a target's actions or its screen's.
    let onRun: (ActionTarget?, ActionTarget.Position) -> Void
    let onEscape: () -> Void
    /// The mic button: start or stop listening.
    let onListen: () -> Void
    /// Follows a link clicked in a page.
    let onOpenLink: (URL) -> Void
    /// The search field's text changed: keeps its caret in view.
    let onQueryChange: () -> Void
    /// Text typed on a page; true if it started something (a Follow Up).
    let onType: (String) -> Bool
    @FocusState private var focus: PaletteFocus?
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .top) {
            GlassEffectContainer(spacing: PaletteMetrics.gap) {
                VStack(spacing: PaletteMetrics.gap) {
                    Color.clear
                        .frame(height: PaletteMetrics.pillHeight)
                        .glassEffect(Self.glass, in: .capsule)
                        .glassEffectID("pill", in: glass)
                    if model.isExpanded {
                        Color.clear
                            .frame(height: model.cardHeight)
                            .glassEffect(Self.glass, in: Self.card)
                            .glassEffectID("card", in: glass)
                    }
                }
            }
            VStack(spacing: PaletteMetrics.gap) {
                searchField
                if model.isExpanded {
                    VStack(spacing: 0) {
                        FrameContent(model: model, onRun: onRun)
                            // Links in pages go through Wicket's own open, never straight to macOS.
                            .environment(
                                \.openURL,
                                OpenURLAction {
                                    onOpenLink($0)
                                    return .handled
                                }
                            )
                            // Each frame keeps its own scroll position; one frame's content replaced
                            // (a live list, a growing answer) updates in place.
                            .id(model.top.id)
                        Divider()
                        FooterBar(
                            primary: model.target.flatMap(model.primaryPresentation),
                            secondary: model.target.flatMap(model.screenSecondaryTitle), toast: model.toast,
                            canGoBack: model.canGoBack)
                    }
                    .frame(height: model.cardHeight)
                    .clipShape(Self.card)
                    .transition(.opacity)
                }
            }
            .overlay {
                if let menu = model.actionMenu {
                    // A click anywhere outside the panel closes it rather than reaching what is beneath.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { model.actionMenu = nil }
                        .overlay(alignment: .bottomTrailing) {
                            ActionPanel(model: model, menu: menu, focus: $focus, onRun: onRun)
                                .padding(.trailing, 10)
                                .padding(.bottom, ActionPanel.bottomPadding)
                        }
                }
            }
        }
        .padding(PaletteMetrics.margin)
        // Top-aligned, so the pill stays put while the window grows and shrinks beneath it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onModifierKeysChanged(mask: .command) { _, keys in model.commandHeld = !keys.isEmpty }
        .onAppear { focus = search }
        .onChange(of: model.focusToken) { focus = search }
        // Each field has its own focus value, so a new field (see `fieldID`) is a real change of
        // focus. Re-asserting one shared value would need clearing it first, and a deferred set
        // after the clear could land before SwiftUI applied the clear, leaving nothing focused.
        .onChange(of: fieldID) { focus = search }
        // Every way the panel closes hands the keyboard back to the search field, so it never
        // unmounts while focused and leaves the window without a first responder.
        .onChange(of: model.actionMenu == nil) { _, closed in focus = closed ? search : .actions }
    }

    /// Tinted: untinted glass is hard to read over busy windows.
    private static var glass: Glass { .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)) }
    private static var card: some Shape { .rect(cornerRadius: PaletteMetrics.cardRadius, style: .continuous) }

    /// The pill's glyph and prompt: search at the root; in a command's frame its icon with the
    /// screen's title, else its title for a page (which takes no text) or while it starts (a live
    /// command's field already searches), else its placeholder; a pushed page's title. Voice never changes the prompt: until words arrive the field reads as usual.
    private var pill: (icon: Item.Icon, prompt: String) {
        switch model.top.content {
        case .search:
            return (.symbol(name: "magnifyingglass"), "Search or run a command")
        case .screen(let frame):
            let title = frame.screen?.title
            guard let command = frame.run?.command else {
                return (.symbol(name: "doc.text"), title ?? "Details")
            }
            let titled = model.top.isMeasured || (model.top.isStarting && command.input != .liveText)
            let prompt = titled ? command.title : command.placeholder ?? command.title
            return (command.icon, title ?? prompt)
        }
    }

    /// A spinner while a command runs, a moving waveform while speech is transcribed into the field
    /// (listening, not armed: armed, the microphone is on but nothing was heard, and the pill stays
    /// as it was, so voice never looks like the field's main input), else the pill's icon.
    @ViewBuilder private var pillGlyph: some View {
        if model.isBusy {
            ProgressView().controlSize(.small)
        } else if model.voice?.isListening == true {
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                .accessibilityLabel("Transcribing speech")
        } else {
            switch pill.icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            case .file:
                IconView(icon: pill.icon, size: 22)
            }
        }
    }

    /// Whether a key press typed text: printable characters, not a control key or one of AppKit's
    /// function keys (the arrows, Page Down), which come as private-use characters.
    static func isTyped(_ characters: String) -> Bool {
        !characters.isEmpty
            && characters.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
    }

    /// The search field's identity: a new field per frame (a keyword opens a frame from inside the
    /// field's own edit, and an editing TextField ignores a binding change made there, so it would
    /// keep showing "week " and append the next keys to it), and per kind, field or title.
    private var fieldID: String { "\(model.top.id)-\(model.top.isMeasured)" }

    /// Whether the field takes a secret (Set Secret's frame).
    private var isSecret: Bool {
        guard case .screen(let frame) = model.top.content else { return false }
        return frame.run?.command.id == .setSecret
    }

    /// The focus value of the current search field.
    private var search: PaletteFocus { .search(fieldID) }

    /// The search field, or on a page (which takes no text) its title as a label that still takes
    /// the keys.
    private var searchField: some View {
        HStack(spacing: 12) {
            pillGlyph
                .frame(width: 24)
            Group {
                if model.top.isMeasured {
                    Text(pill.prompt)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusable(interactions: .edit)
                        .focusEffectDisabled()
                } else if isSecret {
                    // A secret's value is masked like any password field, never shown.
                    SecureField(pill.prompt, text: $model.query)
                        .textFieldStyle(.plain)
                } else {
                    TextField(pill.prompt, text: $model.query)
                        .textFieldStyle(.plain)
                }
            }
            .id(fieldID)
            .font(.system(size: 21))
            // A field scrolls to its caret only as it is typed in; text set from outside (a
            // transcript) moves the caret to the end but leaves the visible part where it was.
            .onChange(of: model.query) { onQueryChange() }
            .focused($focus, equals: search)
            // Return is handled here rather than by `onSubmit`, which ends editing.
            .onKeyPress(.upArrow) {
                model.moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.return) {
                onRun(model.target, model.target?.primary ?? .action(0))
                return .handled
            }
            .onKeyPress(.escape) {
                onEscape()
                return .handled
            }
            // Typing on a document (a page, which has no field) starts a Follow Up with the text.
            .onKeyPress(phases: .down) { press in
                guard model.top.isMeasured, press.modifiers.isDisjoint(with: [.command, .control]),
                    Self.isTyped(press.characters)
                else { return .ignored }
                return onType(press.characters) ? .handled : .ignored
            }
            // Backspace in an empty field dismisses the context, as it would delete a token.
            .onKeyPress(.delete) {
                guard model.query.isEmpty, model.session.context != nil else { return .ignored }
                model.session.dismissContext()
                return .handled
            }
            if let context = model.session.context {
                ContextChip(text: context.summary)
            }
            if let voice = model.voice, voice.isEnabled, model.takesSpeech {
                MicButton(state: voice.state, action: onListen)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.pillHeight)
    }
}

/// The top frame's content in the card: a list (the root's results, or a screen's rows), or a page.
/// A command frame waiting for its first content shows nothing yet; the pill spins. The one place a
/// `Screen` meets its view: a page draws its document and reports its height through `measure`.
private struct FrameContent: View {
    let model: PaletteModel
    let onRun: (ActionTarget?, ActionTarget.Position) -> Void

    /// Reports a page's content height for the frame this view shows, so a view on its way out
    /// never sizes the next frame's card.
    private var measure: (CGFloat) -> Void {
        let frame = model.top.id
        return { [model] in model.measureDetail($0, of: frame) }
    }

    var body: some View {
        if case .screen(let frame) = model.top.content, let document = frame.document,
            case .detail(let detail)? = frame.screen
        {
            DocumentView(
                document: document, metadata: detail.metadata, textSize: model.textSize,
                navigation: model.navigation, onMeasure: measure
            )
            .environment(\.documentFocus, focus)
            .environment(\.loadsOnlineContent, model.loadsOnlineContent)
            .onPreferenceChange(BlockedImagesKey.self) { [model, frame = model.top.id] count in
                model.blockImages(count, of: frame)
            }
        } else if case .screen(let frame) = model.top.content, frame.screen == nil {
            Color.clear
        } else {
            ResultsView(model: model, onRun: onRun)
        }
    }

    /// The selection, a target's click, and the ⌘1 to ⌘9 hints while ⌘ is held.
    private var focus: DocumentFocus {
        let targets = model.results
        var hints: [String: String] = [:]
        if model.commandHeld, model.actionMenu == nil {
            for (index, item) in targets.prefix(9).enumerated() { hints[item.id] = "⌘\(index + 1)" }
        }
        return DocumentFocus(
            selected: model.top.list?.selectedItem?.id, hints: hints,
            run: { [model, onRun] item in onRun(model.top.target(for: item), .action(0)) })
    }
}

/// The result list: a list's summary above its rows, scrolling with them, section titles above
/// their first rows. Each title is drawn with its row, so scrolling to a row shows its title too.
struct ResultsView: View {
    let model: PaletteModel
    let onRun: (ActionTarget?, ActionTarget.Position) -> Void

    var body: some View {
        rows
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // The content's real top, above the summary and the inset: scrolling to the first
                    // row itself would hide them.
                    Color.clear.frame(height: 0).id(Self.top)
                    if let summary = model.top.summary {
                        let frame = model.top.id
                        ListTop(
                            summary: summary, textSize: model.textSize,
                            onMeasure: { [model] in model.measureListTop($0, of: frame) })
                    }
                    if model.results.isEmpty {
                        // Blank while the search or run still goes on, under the card kept from before.
                        Text(model.top.isLoading ? "" : "No Results")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: PaletteMetrics.rowHeight)
                            .padding(PaletteMetrics.rowInset)
                    } else {
                        let headers = model.headers
                        LazyVStack(spacing: PaletteMetrics.rowSpacing) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                VStack(spacing: 0) {
                                    if headers.indices.contains(index), let title = headers[index] {
                                        SectionHeader(title: title)
                                    }
                                    ResultRow(
                                        item: item, isProminent: ResultRow.isProminent(item, at: index),
                                        isSelected: model.top.list?.hasSelection == true
                                            && index == model.selection,
                                        hint: hint(for: index)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { onRun(model.top.target(for: item), .action(0)) }
                                    .accessibilityAction { onRun(model.top.target(for: item), .action(0)) }
                                }
                            }
                        }
                        .padding(PaletteMetrics.rowInset)
                    }
                }
            }
            .scrollIndicators(.never)
            // The system's soft edge where rows pass under the footer, instead of a row cut in half.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // Navigation reveals the selected row, however far below the summary; only Up on the
            // first row goes back to the top.
            .onChange(of: model.navigation) { _, navigation in
                guard let navigation, model.results.indices.contains(model.selection) else { return }
                if navigation.showsListTop {
                    proxy.scrollTo(Self.top, anchor: .top)
                } else {
                    proxy.scrollTo(model.results[model.selection].id)
                }
            }
            .onAppear {
                // Back from a pushed frame: show the selection where it was left.
                guard model.selection > 0, let item = model.top.list?.selectedItem else { return }
                proxy.scrollTo(item.id)
            }
            .onChange(of: model.results) {
                // The selection follows its item across updates; at the top, show the list's start.
                guard let item = model.top.list?.selectedItem else { return }
                if model.selection == 0 {
                    proxy.scrollTo(Self.top, anchor: .top)
                } else {
                    proxy.scrollTo(item.id)
                }
            }
        }
    }

    private static let top = "top"

    /// "⌘1" to "⌘9" while ⌘ is held: the chords that run the first nine rows.
    private func hint(for index: Int) -> String? {
        guard model.commandHeld, model.actionMenu == nil, index < 9 else { return nil }
        return "⌘\(index + 1)"
    }
}

/// The bar under the results or a detail: a command's message for a moment, the screen's own
/// action ⌘↩ runs (Follow Up), what Return does and where the other actions are; with nothing to
/// run in a pushed frame, how to go back.
struct FooterBar: View {
    static let height: CGFloat = 34
    /// What Return runs, named as it really runs.
    let primary: ActionPresentation?
    /// The screen action ⌘↩ runs, if ⌘↩ runs one.
    var secondary: String?
    var toast: Message?
    /// A frame is pushed: Escape goes back, shown when there is no action to hint at.
    var canGoBack = false

    var body: some View {
        HStack(spacing: 10) {
            if let toast {
                Label(toast.text, systemImage: toast.kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity)
            } else if let secondary {
                KeyHint(title: secondary, keys: "⌘↩")
            }
            Spacer()
            if let primary {
                KeyHint(title: primary.title, keys: "↩")
                Divider().frame(height: 14)
                KeyHint(title: "Actions", keys: "⌘K")
            } else if canGoBack {
                KeyHint(title: "Back", keys: "esc")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
    }
}

private struct KeyHint: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
            KeyCap(keys)
        }
    }
}

private struct KeyCap: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 4))
    }
}

/// The action panel: every action of what it was opened on, filtered by its own field, then the
/// screen's own actions as a group named after the screen ("Answer").
struct ActionPanel: View {
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let padding: CGFloat = 6
    static let radius: CGFloat = 16
    static let fieldHeight: CGFloat = 34
    /// It sits just above the footer.
    static let bottomPadding = FooterBar.height + 4
    /// Room the card keeps around the panel: below it, and above it so it never covers the pill.
    static let clearance = bottomPadding + 8
    /// The most rows the panel shows at once: as many whole rows as the tallest card holds. More
    /// scroll.
    static let maxRows = Int(
        (PaletteMetrics.maxCardHeight - clearance - fieldHeight - 1 - 2 * padding + rowSpacing)
            / (rowHeight + rowSpacing))

    /// The height of the panel's rows (with their padding) for `rows` lines (actions and the screen
    /// group's title, which is a row tall), up to `maxRows`.
    static func listHeight(rows: Int) -> CGFloat {
        let rows = CGFloat(min(max(rows, 1), maxRows))
        return 2 * padding + rows * (rowHeight + rowSpacing) - rowSpacing
    }

    /// The panel's height for `rows` actions.
    static func height(rows: Int) -> CGFloat {
        listHeight(rows: rows) + 1 + fieldHeight
    }

    @Bindable var model: PaletteModel
    let menu: ActionMenu
    var focus: FocusState<PaletteFocus?>.Binding
    let onRun: (ActionTarget?, ActionTarget.Position) -> Void

    var body: some View {
        let rows = menu.rows
        let selected = menu.selectedRow?.id
        let firstScreen = rows.first { if case .screen = $0.id { true } else { false } }?.id
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        if rows.isEmpty {
                            Text("No Matching Actions")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(height: Self.rowHeight)
                        }
                        ForEach(rows) { row in
                            if row.id == firstScreen {
                                GroupTitle(title: menu.screenTitle, separated: rows.first?.id != firstScreen)
                            }
                            ActionRow(
                                row: row, shortcut: menu.shortcut(for: row.id), isSelected: row.id == selected
                            )
                            .contentShape(.rect)
                            .onTapGesture { onRun(menu.target, row.id) }
                            .accessibilityAction { onRun(menu.target, row.id) }
                        }
                    }
                    .padding(Self.padding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: Self.listHeight(rows: rows.count + (firstScreen == nil ? 0 : 1)))
                .onChange(of: selected) { _, selected in
                    if let selected { proxy.scrollTo(selected) }
                }
            }
            Divider()
            TextField("Search actions…", text: filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus, equals: .actions)
                .onKeyPress(.upArrow) {
                    model.actionMenu?.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.actionMenu?.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    if let row = model.actionMenu?.selectedRow { onRun(menu.target, row.id) }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if menu.filter.isEmpty { model.actionMenu = nil } else { model.actionMenu?.filter = "" }
                    return .handled
                }
                .padding(.horizontal, 12)
                .frame(height: Self.fieldHeight)
        }
        .frame(width: 320)
        .background(.regularMaterial, in: .rect(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var filter: Binding<String> {
        Binding(get: { menu.filter }, set: { model.actionMenu?.filter = $0 })
    }
}

/// The title of the screen's group in the action panel, a row tall, under a hairline when actions
/// come before it.
private struct GroupTitle: View {
    let title: String
    let separated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if separated {
                Divider().padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: ActionPanel.rowHeight)
    }
}

private struct ActionRow: View {
    let row: ActionMenu.Row
    let shortcut: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.presentation.symbol)
                .frame(width: 18)
            Text(row.presentation.title)
                .layoutPriority(1)
            if let detail = row.presentation.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let shortcut {
                KeyCap(shortcut)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: ActionPanel.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: ActionPanel.radius - ActionPanel.padding, style: .continuous)
                    .fill(.primary.opacity(0.1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [row.presentation.title, row.presentation.detail].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A result. An answer at the top (a calculation, an extension's answer) is shown large: the result
/// is the point, so it gets the big text and its interpretation the small line below. It stays large
/// while the selection moves, so the list never reflows under the arrow keys. A file row without an
/// accessory of its producer's shows when the file was modified, read off the main actor.
struct ResultRow: View {
    let item: Item
    let isProminent: Bool
    let isSelected: Bool
    /// Replaces the accessory while ⌘ is held.
    let hint: String?
    /// How much larger than a list's row it draws: a document's rows follow its text size.
    var scale: CGFloat = 1
    /// The file's modification date, for a file row without an accessory; nil until read.
    @State private var modified: Date?

    static func isProminent(_ item: Item, at index: Int) -> Bool {
        index == 0 && item.relevance == .answer
    }

    /// The file whose date is the row's accessory: a file subject's, when the producer sent none.
    private var datedFile: URL? {
        guard item.accessory == nil, case .file(let url)? = item.subject else { return nil }
        return url
    }

    private var accessory: String? {
        item.accessory ?? modified.map { FileDate.text($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: item.icon, size: 26 * scale)
            if isProminent {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            } else {
                // One line per row, the subtitle beside the title: every row the same height, and a
                // long path gives way (truncated in the middle) before the title does.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .layoutPriority(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: (14 * scale).rounded()))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let accessory = hint ?? accessory {
                Text(accessory)
                    .font(.system(size: (13 * scale).rounded()))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: (isProminent ? PaletteMetrics.answerRowHeight : PaletteMetrics.rowHeight) * scale)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: PaletteMetrics.rowRadius, style: .continuous)
                    .fill(.primary.opacity(0.1))
            }
        }
        .task(id: datedFile) {
            modified = nil
            if let datedFile { modified = await FileDate.load(datedFile) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilityLabel(title: item.title, subtitle: item.subtitle, accessory: accessory)
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// What VoiceOver reads for a row: its name, then its subtitle (a file's folder) and accessory.
    static func accessibilityLabel(title: String, subtitle: String?, accessory: String?) -> String {
        [title, subtitle, accessory].compactMap { $0 }.joined(separator: ", ")
    }
}

/// At the pill's end while voice is on: starts or stops listening, like ⌘L. Armed on open, it is
/// filled, so the field says the microphone is on without anything else showing.
private struct MicButton: View {
    let state: VoiceInput.State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .idle ? "mic" : "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(state == .listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(state == .listening ? "Stop Listening (⌘L)" : "Start Listening (⌘L)")
        .accessibilityLabel(state == .listening ? "Stop Listening" : "Start Listening")
        .accessibilityValue(state == .idle ? "" : state == .armed ? "Microphone on" : "Transcribing")
    }
}

/// The Finder selection Run Agent will get (`SummonContext.summary`), at the pill's end:
/// "Finder · 3 items". Backspace in an empty field dismisses it.
private struct ContextChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .fixedSize()
            .help("The agent works in these files' folder. Press Delete in an empty field to leave them out.")
            .accessibilityLabel("Context: \(text)")
    }
}
