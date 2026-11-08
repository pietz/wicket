import AppKit
import SwiftUI
import WicketCore

/// Row icons. A symbol is drawn at once; a Finder icon is rendered off the main actor the first
/// time and cached, so a list of files or apps never stalls the keystroke or the scroll on disk
/// and Launch Services: the row keeps an empty square until its icon arrives.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    nonisolated static let size = NSSize(width: 32, height: 32)

    /// One entry per symbol name and per file, whatever spelling named the file (`/tmp/../tmp/x`).
    nonisolated static func key(for icon: Item.Icon) -> String {
        switch icon {
        case .file(let url): "file:" + url.standardizedFileURL.path(percentEncoded: false)
        case .symbol(let name): "symbol:" + name
        }
    }

    /// The icon if it can be had without waiting: a symbol always, a Finder icon once loaded.
    static func cached(_ icon: Item.Icon) -> NSImage? {
        let key = key(for: icon) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard case .symbol(let name) = icon else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image =
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage()
        image.size = size
        cache.setObject(image, forKey: key)
        return image
    }

    /// The icon, rendering a Finder icon off the main actor if it isn't cached yet.
    static func load(_ icon: Item.Icon) async -> NSImage {
        if let image = cached(icon) { return image }
        guard case .file(let url) = icon else { return NSImage() }
        let path = url.path(percentEncoded: false)
        let rendered = await Task.detached(priority: .userInitiated) { Rendered(path: path) }.value
        let image = rendered.image.map { NSImage(cgImage: $0, size: size) } ?? NSImage()
        cache.setObject(image, forKey: key(for: icon) as NSString)
        return image
    }

    /// A Finder icon drawn into a bitmap, so the lazy `NSImage` never renders on the main actor.
    private struct Rendered: @unchecked Sendable {
        let image: CGImage?

        init(path: String) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            var rect = CGRect(x: 0, y: 0, width: 2 * IconCache.size.width, height: 2 * IconCache.size.height)
            image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
}

/// An item's icon at `size`, from `IconCache`.
struct IconView: View {
    let icon: Item.Icon
    var size: CGFloat = 26
    /// The last icon loaded, with what it is the icon of, so a changed icon never shows the old one.
    @State private var loaded: (icon: Item.Icon, image: NSImage)?

    var body: some View {
        Group {
            if let image = IconCache.cached(icon) ?? (loaded?.icon == icon ? loaded?.image : nil) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: icon) {
            guard IconCache.cached(icon) == nil else { return }
            loaded = (icon, await IconCache.load(icon))
        }
    }
}

/// What a file row shows beside what the producer sent: when the file was last modified, read off
/// the main actor as the row appears.
enum FileDate {
    /// The file's modification date; nil if it isn't there.
    static func load(_ url: URL) async -> Date? {
        await Task.detached(priority: .userInitiated) {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.value
    }

    /// `date` as a row's accessory: "Now", relative within a week ("12 min. ago", "yesterday"),
    /// else the day ("Oct 30"), with the year when it isn't this one.
    static func text(
        _ date: Date, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current
    )
        -> String
    {
        let age = now.timeIntervalSince(date)
        if age < 60, age > -60 { return "Now" }
        if age > 0, age < 7 * 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: now)
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar)
            .month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
