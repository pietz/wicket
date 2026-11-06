import AppKit
import SwiftUI
import WicketCore

/// Which field has the keyboard: the search field, or the action panel's filter while it is open.
enum PaletteFocus: Hashable {
    case search, actions
}

/// The palette's sizes. The window is the visible shapes plus a transparent `margin`, where the
/// glass draws its rim. The width is a setting (`paletteWidth`); the content follows the window's.
enum PaletteMetrics {
    static let pillHeight: CGFloat = 56
    static let gap: CGFloat = 8
    static let cardHeight: CGFloat = 384
    static let cardRadius: CGFloat = 24
    /// Inset of the rows from the card's edge; their highlight stays concentric with its corners.
    static let rowInset: CGFloat = 8
    static let margin: CGFloat = 40

    static func windowSize(width: CGFloat, expanded: Bool) -> NSSize {
        let content = expanded ? pillHeight + gap + cardHeight : pillHeight
        return NSSize(width: width + 2 * margin, height: content + 2 * margin)
    }
}

/// The palette: a Liquid Glass pill holding the search field and, while there is something to show,
/// a glass card under it with the results and footer, with the action panel (⌘K) over them. The
/// glass shapes sit in one container, so the card morphs out of the pill; the content is layered
/// above the container, where a morph can't smear it.
///
/// Chords (⌘K, ⌘↩, ⌘1 to ⌘9, ⌃N, ⌃P) are handled by `PalettePanel` before these fields see them;
/// plain keys are handled here, by whichever field has focus.
struct PaletteRootView: View {
    @Bindable var model: PaletteModel
    /// Runs the action at a position in an item's actions.
    let onRun: (Item?, Int) -> Void
    let onHide: () -> Void
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
                            .frame(height: PaletteMetrics.cardHeight)
                            .glassEffect(Self.glass, in: Self.card)
                            .glassEffectID("card", in: glass)
                    }
                }
            }
            VStack(spacing: PaletteMetrics.gap) {
                searchField
                if model.isExpanded {
                    VStack(spacing: 0) {
                        ResultsView(model: model, onRun: onRun)
                        Divider()
                        FooterBar(item: model.selectedItem)
                    }
                    .frame(height: PaletteMetrics.cardHeight)
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
                                .padding(.bottom, FooterBar.height + 4)
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
        // Every way the panel closes hands the keyboard back to the search field, so it never
        // unmounts while focused and leaves the window without a first responder.
        .onChange(of: model.actionMenu == nil) { _, closed in focus = closed ? .search : .actions }
    }

    /// Tinted: untinted glass is hard to read over busy windows.
    private static var glass: Glass { .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)) }
    private static var card: some Shape { .rect(cornerRadius: PaletteMetrics.cardRadius, style: .continuous) }

    // Return is handled here rather than by `onSubmit`, which ends editing.
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            TextField(model.mode.prompt, text: $model.query)
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
                    onRun(model.selectedItem, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { onHide() } else { model.query = "" }
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteMetrics.pillHeight)
    }
}

/// The result list.
struct ResultsView: View {
    let model: PaletteModel
    let onRun: (Item?, Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        ResultRow(item: item, isSelected: index == model.selection, hint: hint(for: index))
                            .contentShape(Rectangle())
                            .onTapGesture { onRun(item, 0) }
                    }
                }
                .padding(PaletteMetrics.rowInset)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                guard model.results.indices.contains(selection) else { return }
                proxy.scrollTo(model.results[selection].id)
            }
            .onChange(of: model.results) {
                // The selection follows its item across updates; at the top, show the list's start.
                guard let item = model.selectedItem else { return }
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

/// The bar under the results: what Return does, and where the other actions are.
struct FooterBar: View {
    static let height: CGFloat = 34
    let item: Item?

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if let item, let primary = item.actions.first {
                KeyHint(title: ActionPresentation(primary).title, keys: "↩")
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

/// The action panel: every action of the item it was opened on, filtered by its own field.
private struct ActionPanel: View {
    @Bindable var model: PaletteModel
    let menu: ActionMenu
    var focus: FocusState<PaletteFocus?>.Binding
    let onRun: (Item?, Int) -> Void

    var body: some View {
        let rows = menu.rows
        let selected = menu.selectedRow?.id
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text("No Matching Actions")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(height: 30)
                }
                ForEach(rows) { row in
                    ActionRow(row: row, isSelected: row.id == selected)
                        .contentShape(.rect)
                        .onTapGesture { onRun(menu.item, row.id) }
                }
            }
            .padding(6)
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
                    if let row = model.actionMenu?.selectedRow { onRun(menu.item, row.id) }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if menu.filter.isEmpty { model.actionMenu = nil } else { model.actionMenu?.filter = "" }
                    return .handled
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
        }
        .frame(width: 320)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
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
        .frame(height: 30)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.1))
            }
        }
    }
}

private struct ResultRow: View {
    let item: Item
    let isSelected: Bool
    /// Replaces the accessory while ⌘ is held.
    let hint: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.image(for: item.icon))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
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
        .frame(height: 40)
        .background {
            if isSelected {
                RoundedRectangle(
                    cornerRadius: PaletteMetrics.cardRadius - PaletteMetrics.rowInset, style: .continuous
                )
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
