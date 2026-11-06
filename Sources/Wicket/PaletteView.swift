import AppKit
import SwiftUI

/// The palette: search field and results, on Liquid Glass.
struct PaletteRootView: View {
    @Bindable var model: PaletteModel
    let onActivate: (Int) -> Void
    let onHide: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($focused)
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.return) { onActivate(model.selection); return .handled }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { onHide() } else { model.query = "" }
                    return .handled
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)
            Divider()
            ResultsView(model: model, onActivate: onActivate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tinted: untinted glass is hard to read over busy windows.
        .glassEffect(
            .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)),
            in: .rect(cornerRadius: 22))
        .clipShape(.rect(cornerRadius: 22))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }
}

/// The result list.
struct ResultsView: View {
    let model: PaletteModel
    let onActivate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        ResultRow(item: item, isSelected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(index) }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, selection in
                guard model.results.indices.contains(selection) else { return }
                proxy.scrollTo(model.results[selection].id)
            }
            .onChange(of: model.results) { _, results in
                if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }
}

private struct ResultRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.image(for: item.icon))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
            Text(item.title)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.accessory)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.1))
            }
        }
    }
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static let size = NSSize(width: 32, height: 32)

    static func image(for icon: PaletteItem.Icon) -> NSImage {
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
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
        }
        image.size = size
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
