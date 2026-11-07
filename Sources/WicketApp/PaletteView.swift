import AppKit
import SwiftUI
import WicketCore

/// Which field has the keyboard: the search field, or the action panel's filter while it is open.
enum PaletteFocus: Hashable {
    case search, actions
}

/// The palette's sizes. The window is the visible shapes plus a transparent `margin`, where the
/// glass draws its rim. The width is a setting (`paletteWidth`); the content follows the window's.
@MainActor
enum PaletteMetrics {
    static let pillHeight: CGFloat = 56
    static let gap: CGFloat = 8
    /// The tallest card: eight rows, with a sliver of the next one hinting that the list scrolls.
    static let maxCardHeight: CGFloat = 384
    static let cardRadius: CGFloat = 24
    /// Inset of the rows from the card's edge; their highlight stays concentric with its corners.
    static let rowInset: CGFloat = 8
    static let rowHeight: CGFloat = 40
    /// An answer at the top, such as a calculation, shown large.
    static let answerRowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 2
    static let margin: CGFloat = 40

    /// The card for `frame`, up to `maxCardHeight`, and while the action panel is open at least tall
    /// enough for it. A compact frame has none. Rows fit the card (with the divider and footer),
    /// computed; a screen without rows (a page) fits its content as measured (`detailHeight`), since
    /// markdown wraps. The root search has no card without results, a command's empty list shows one
    /// row saying so. Nil, keep the card as it is, while a command frame waits for its first content
    /// or a page for its first measurement.
    static func cardHeight(for frame: Frame, actionMenu: ActionMenu?, detailHeight: CGFloat?) -> CGFloat? {
        if frame.isCompact { return 0 }
        if frame.isMeasured { return detailHeight.map { card(content: $0, actionMenu: actionMenu) } }
        guard let results = frame.list?.items else { return nil }
        if case .search = frame.content, results.isEmpty { return 0 }
        var rows = CGFloat(max(results.count, 1)) * (rowHeight + rowSpacing) - rowSpacing + 2 * rowInset
        if let first = results.first, ResultRow.isProminent(first, at: 0) {
            rows += answerRowHeight - rowHeight
        }
        return card(content: rows, actionMenu: actionMenu)
    }

    /// A detail's card before its content is laid out, when no card is up to keep: the view must be
    /// on screen to be measured, so it opens this small (under any page's height) and grows to fit.
    static let unmeasuredDetailHeight = rowHeight + 1 + FooterBar.height

    /// The card for `content` above the divider and footer.
    private static func card(content: CGFloat, actionMenu: ActionMenu?) -> CGFloat {
        let menu =
            actionMenu.map { ActionPanel.height(rows: $0.target.actions.count) + ActionPanel.clearance } ?? 0
        return min(max((content + 1 + FooterBar.height).rounded(.up), menu), maxCardHeight)
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
/// Chords (⌘K, ⌘↩, ⌘1 to ⌘9, ⌃N, ⌃P) are handled by `PalettePanel` before these fields see them;
/// plain keys are handled here, by whichever field has focus.
struct PaletteRootView: View {
    @Bindable var model: PaletteModel
    /// Runs the action at a position in a target's actions.
    let onRun: (ActionTarget?, Int) -> Void
    let onEscape: () -> Void
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
                            // Each frame keeps its own scroll position; one frame's content replaced
                            // (a live list, a growing answer) updates in place.
                            .id(model.top.id)
                        Divider()
                        FooterBar(target: model.target, toast: model.toast, pasteTarget: model.pasteTarget)
                    }
                    .frame(height: model.cardHeight)
                    .clipShape(Self.card)
                    // Rows inside take concentric corners from the card (macOS 26's ConcentricRectangle).
                    .containerShape(
                        RoundedRectangle(cornerRadius: PaletteMetrics.cardRadius, style: .continuous)
                    )
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
        .onAppear { focus = .search }
        .onChange(of: model.focusToken) { focus = .search }
        // The field is new (see `searchField`), and focus already says `.search`, so setting it
        // again would be ignored: clear it, then focus the new field once it exists.
        .onChange(of: model.top.id) {
            focus = nil
            Task { @MainActor in focus = .search }
        }
        // Every way the panel closes hands the keyboard back to the search field, so it never
        // unmounts while focused and leaves the window without a first responder.
        .onChange(of: model.actionMenu == nil) { _, closed in focus = closed ? .search : .actions }
    }

    /// Tinted: untinted glass is hard to read over busy windows.
    private static var glass: Glass { .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)) }
    private static var card: some Shape { .rect(cornerRadius: PaletteMetrics.cardRadius, style: .continuous) }

    /// The pill's glyph and prompt: search at the root; in a command's frame its icon with the
    /// screen's title, else its title for a page (which takes no text) or its placeholder; a pushed
    /// page's title.
    private var pill: (icon: Item.Icon, prompt: String) {
        switch model.top.content {
        case .search:
            return (.symbol(name: "magnifyingglass"), "Search or run a command")
        case .screen(let frame):
            let title = frame.screen?.title
            guard let command = frame.run?.command else {
                return (.symbol(name: "doc.text"), title ?? "Details")
            }
            let prompt = model.top.isMeasured ? command.title : command.placeholder ?? command.title
            return (command.icon, title ?? prompt)
        }
    }

    /// A spinner while a command runs, else the pill's icon.
    @ViewBuilder private var pillGlyph: some View {
        if model.isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch pill.icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            case .file:
                Image(nsImage: IconCache.image(for: pill.icon))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }
        }
    }

    // Return is handled here rather than by `onSubmit`, which ends editing.
    private var searchField: some View {
        HStack(spacing: 12) {
            pillGlyph
                .frame(width: 24)
            TextField(pill.prompt, text: $model.query)
                // A new field per frame: a keyword opens a frame from inside the field's own edit,
                // and an editing TextField ignores a binding change made there, so it would keep
                // showing "week " and append the next keys to it.
                .id(model.top.id)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .focused($focus, equals: .search)
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    onRun(model.target, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onEscape()
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.pillHeight)
    }
}

/// The top frame's content in the card: a list (the root's results, or a screen's rows), or a page.
/// A command frame waiting for its first content shows nothing yet; the pill spins. The one place a
/// `Screen` case meets its view: a view without rows reports its height through `measure`.
private struct FrameContent: View {
    let model: PaletteModel
    let onRun: (ActionTarget?, Int) -> Void

    /// Reports a detail's content height for the frame this view shows, so a view on its way out
    /// never sizes the next frame's card.
    private var measure: (CGFloat) -> Void {
        let frame = model.top.id
        return { [model] in model.measureDetail($0, of: frame) }
    }

    var body: some View {
        switch model.top.content {
        case .search: ResultsView(model: model, onRun: onRun)
        case .screen(let frame):
            switch frame.screen {
            case .answer, .list: ResultsView(model: model, onRun: onRun)
            case .detail(let detail): DetailView(detail: detail, onMeasure: measure)
            case nil: Color.clear
            }
        }
    }
}

/// The result list.
struct ResultsView: View {
    let model: PaletteModel
    let onRun: (ActionTarget?, Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.results.isEmpty {
                    // Only a command's list gets here: the root search has no card without results.
                    Text(model.top.isLoading ? "" : "No Results")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: PaletteMetrics.rowHeight)
                        .padding(PaletteMetrics.rowInset)
                }
                LazyVStack(spacing: PaletteMetrics.rowSpacing) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        ResultRow(
                            item: item, isProminent: ResultRow.isProminent(item, at: index),
                            isSelected: index == model.selection, hint: hint(for: index)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onRun(ActionTarget(item: item), 0) }
                    }
                }
                .padding(PaletteMetrics.rowInset)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                guard model.results.indices.contains(selection) else { return }
                proxy.scrollTo(model.results[selection].id)
            }
            .onAppear {
                // Back from a pushed frame: show the selection where it was left.
                guard model.selection > 0, let item = model.top.list?.selectedItem else { return }
                proxy.scrollTo(item.id)
            }
            .onChange(of: model.results) {
                // The selection follows its item across updates; at the top, show the list's start.
                guard let item = model.top.list?.selectedItem else { return }
                proxy.scrollTo(item.id, anchor: model.selection == 0 ? .top : nil)
            }
        }
    }

    /// "⌘1" to "⌘9" while ⌘ is held: the chords that run the first nine rows.
    private func hint(for index: Int) -> String? {
        guard model.commandHeld, model.actionMenu == nil, index < 9 else { return nil }
        return "⌘\(index + 1)"
    }
}

/// The bar under the results or a detail: a command's message for a moment, what Return does, and
/// where the other actions are.
struct FooterBar: View {
    static let height: CGFloat = 34
    let target: ActionTarget?
    var toast: String?
    var pasteTarget: String?

    var body: some View {
        HStack(spacing: 10) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer()
            if let primary = target?.actions.first {
                KeyHint(title: ActionPresentation(primary, pasteTarget: pasteTarget).title, keys: "↩")
                Divider().frame(height: 14)
                KeyHint(title: "Actions", keys: "⌘K")
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

/// The action panel: every action of what it was opened on, filtered by its own field.
struct ActionPanel: View {
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let padding: CGFloat = 6
    static let fieldHeight: CGFloat = 34
    /// It sits just above the footer.
    static let bottomPadding = FooterBar.height + 4
    /// Room the card keeps around the panel: below it, and above it so it never covers the pill.
    static let clearance = bottomPadding + 8

    /// The panel's height with every one of `rows` actions showing.
    static func height(rows: Int) -> CGFloat {
        let rows = CGFloat(max(rows, 1))
        return 2 * padding + rows * (rowHeight + rowSpacing) - rowSpacing + 1 + fieldHeight
    }

    @Bindable var model: PaletteModel
    let menu: ActionMenu
    var focus: FocusState<PaletteFocus?>.Binding
    let onRun: (ActionTarget?, Int) -> Void

    var body: some View {
        let rows = menu.rows
        let selected = menu.selectedRow?.id
        VStack(spacing: 0) {
            VStack(spacing: Self.rowSpacing) {
                if rows.isEmpty {
                    Text("No Matching Actions")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.rowHeight)
                }
                ForEach(rows) { row in
                    ActionRow(row: row, isSelected: row.id == selected)
                        .contentShape(.rect)
                        .onTapGesture { onRun(menu.target, row.id) }
                }
            }
            .padding(Self.padding)
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
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var filter: Binding<String> {
        Binding(get: { menu.filter }, set: { model.actionMenu?.filter = $0 })
    }
}

private struct ActionRow: View {
    let row: ActionMenu.Row
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
            if let shortcut = ActionPresentation.shortcut(at: row.id) {
                KeyCap(shortcut)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: ActionPanel.rowHeight)
        .background {
            if isSelected {
                ConcentricRectangle(corners: .concentric(minimum: 6), isUniform: false)
                    .fill(.primary.opacity(0.1))
            }
        }
    }
}

/// A result. An answer at the top (a calculation, an extension's answer) is shown large: the result
/// is the point, so it gets the big text and its interpretation the small line below. It stays large
/// while the selection moves, so the list never reflows under the arrow keys.
struct ResultRow: View {
    let item: Item
    let isProminent: Bool
    let isSelected: Bool
    /// Replaces the accessory while ⌘ is held.
    let hint: String?

    static func isProminent(_ item: Item, at index: Int) -> Bool {
        index == 0 && item.relevance == .answer
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.image(for: item.icon))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: isProminent ? 0 : 1) {
                Text(item.title)
                    .font(
                        isProminent ? .system(size: 24, weight: .medium).monospacedDigit() : .system(size: 14)
                    )
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: isProminent ? 12 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let accessory = hint ?? item.accessory {
                Text(accessory)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: isProminent ? PaletteMetrics.answerRowHeight : PaletteMetrics.rowHeight)
        .background {
            if isSelected {
                // Concentric with the card where the row meets its corners, a small radius elsewhere,
                // so a mid-list selection isn't a pill and the top row follows the card's curve.
                ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: false)
                    .fill(.primary.opacity(0.1))
            }
        }
    }
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static let size = NSSize(width: 32, height: 32)

    static func image(for icon: Item.Icon) -> NSImage {
        let key: String
        switch icon {
        case .file(let url): key = url.path
        case .symbol(let name): key = "symbol:" + name
        }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image: NSImage
        switch icon {
        case .file(let url):
            image = NSWorkspace.shared.icon(forFile: url.path)
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            image =
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
        }
        image.size = size
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
