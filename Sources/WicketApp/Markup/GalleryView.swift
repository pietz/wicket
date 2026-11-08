import SwiftUI
import WicketCore

/// `<image>`s: one alone, or a gallery of adjacent ones, up to three a line. Each is a target whose
/// Return opens its source; its alt text is what VoiceOver reads and its caption and web host sit
/// under it. The space is kept while it loads, so the page doesn't jump.
struct GalleryView: ComponentView {
    let node: Gallery
    @Environment(\.textSize) private var textSize

    init(_ node: Gallery) { self.node = node }

    /// The most images on a line.
    static let perLine = 3

    var body: some View {
        if node.images.count == 1 {
            ImageTile(image: node.images[0], height: 200 * textSize.scale)
        } else {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: min(node.images.count, Self.perLine))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(node.images.enumerated()), id: \.offset) { _, image in
                    ImageTile(image: image, height: 130 * textSize.scale)
                }
            }
        }
    }
}

/// How many images on a page wait for "Show online content" or Load Images, summed over the page.
struct BlockedImagesKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

private struct ImageTile: View {
    let image: Gallery.Image
    let height: CGFloat
    @Environment(\.textSize) private var textSize
    @Environment(\.loadsOnlineContent) private var online
    @State private var loaded: (url: URL, image: NSImage?)?

    private var isRemote: Bool { !image.source.isFileURL }
    private var blocked: Bool { isRemote && !online }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            picture
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            if image.caption != nil || isRemote {
                HStack(spacing: 6) {
                    if let caption = image.caption { Text(caption).lineLimit(2) }
                    if isRemote, let host = image.source.host() {
                        Label(host, systemImage: "globe")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .accessibilityLabel("from \(host)")
                    }
                }
                .font(.system(size: textSize.points(11)))
                .foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image.alt ?? "Image")
        .accessibilityAddTraits(.isImage)
        .target(image.item, radius: 13)
        .padding(-4)
        .preference(key: BlockedImagesKey.self, value: blocked ? 1 : 0)
        .task(id: online ? image.source : nil) {
            guard !blocked, loaded?.url != image.source else { return }
            if let cached = ImageLoader.shared.cached(image.source) {
                loaded = (image.source, cached)
                return
            }
            let result = await ImageLoader.shared.load(image.source)
            guard !Task.isCancelled else { return }
            loaded = (image.source, result)
        }
    }

    @ViewBuilder private var picture: some View {
        if let shown = loaded?.url == image.source ? loaded?.image : ImageLoader.shared.cached(image.source) {
            Image(nsImage: shown)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: height)
                .clipped()
        } else if blocked || loaded?.url == image.source {
            // Not loaded while online content is off, or it couldn't be had.
            Image(systemName: blocked ? "photo.badge.arrow.down" : "photo")
                .font(.system(size: textSize.points(20)))
                .foregroundStyle(.tertiary)
        }
    }
}
