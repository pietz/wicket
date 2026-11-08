import AppKit
import Foundation
import SwiftUI
import Testing
import WicketCore

@testable import WicketApp

/// Renders real palettes to PNG files off-screen, for looking at the views when no screen is free:
/// the gallery's screens and two agent answers, as the palette draws them at its default width,
/// with the card sized by the controller's rule from the views' own measurements. Opt in with
/// `WICKET_SNAPSHOTS=<folder>`; the files are named `<screen>-<appearance>-<text size>.png`. The
/// glass doesn't draw off-screen, so the pill and card are drawn in the window's color over a grey
/// desktop instead; web images show their placeholder.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WICKET_SNAPSHOTS"] != nil))
struct SnapshotTests {
    let runner = FakeRunner()
    let folder = URL(filePath: ProcessInfo.processInfo.environment["WICKET_SNAPSHOTS"] ?? "/dev/null")
    static let gallery = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Extensions/gallery").standardized

    @Test func galleryScreens() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = try Manifest.load(from: Self.gallery)
        for name in ["gallery", "weather", "compare", "repo", "person", "calendar", "invoices"] {
            let data = try Data(contentsOf: Self.gallery.appending(path: "screens/\(name).json"))
            let response = try Response.decode(data, context: WireContext(command: name, in: manifest))
            guard case .success(.show(let screen, let context)) = response else {
                Issue.record("\(name) is not a screen")
                continue
            }
            let title = manifest.command(name)?.title ?? name
            let sizes: [TextSize] = ["weather", "compare"].contains(name) ? [.medium, .large] : [.medium]
            for size in sizes {
                for dark in [false, true] {
                    try await snapshot(name, screen, context, title: title, dark: dark, size: size)
                }
            }
            if name == "weather" {
                for dark in [false, true] {
                    try await snapshot(
                        "weather-selected", screen, context, title: title, dark: dark, size: .medium,
                        select: 1)
                }
            }
        }
    }

    @Test func agentAnswers() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = ScreenContext(
            authority: .agent,
            actions: [
                .copy(text: "", title: "Copy Answer"),
                .run(command: .runAgent, text: "", title: "Follow Up"),
                .paste(text: "", title: "Paste Answer"),
            ], secondary: 1)
        let answers = [
            ("answer-value", "How old is Keanu Reeves?", Self.oneValue),
            ("answer-mixed", "How did revenue do this year?", Self.mixed),
        ]
        for (name, question, markup) in answers {
            for dark in [false, true] {
                try await snapshot(
                    name, .detail(Detail(title: question, markdown: markup)), context, title: "Run Agent",
                    dark: dark, size: .medium)
            }
        }
    }

    /// A card with a local image beside facts, portrait and landscape: how an image in a column is
    /// sized once it has loaded.
    @Test func imagesBesideFacts() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, width, height) in [("card-portrait", 600, 800), ("card-landscape", 1200, 700)] {
            let file = folder.appending(path: ".\(name)-source.png")
            try Self.picture(width: width, height: height).write(to: file)
            let markup = """
                <card title="Ada Lovelace">
                <columns>
                <image src="\(file.path)" alt="A picture"/>
                <facts>
                <fact label="Born" value="10 Dec 1815"/>
                <fact label="Known for" value="The first program"/>
                </facts>
                </columns>
                </card>
                """
            _ = await ImageLoader.shared.load(file)
            try await snapshot(
                name, .detail(Detail(title: "Who was Ada Lovelace?", markdown: markup)), .host, title: "Ask",
                dark: false, size: .medium)
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A PNG of a vertical gradient, `width` by `height` pixels.
    private static func picture(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let colors = [
            CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            CGColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1),
        ]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    static let oneValue = """
        <answer value="62" detail="Born September 2, 1964, in Beirut"/>
        """

    /// After the revenue reply in docs/reviews/2026-11-08-markup-eval.md.
    static let mixed = """
        Revenue grew every quarter this year, with the strongest jump in Q3 after the price change. \
        The full figures are in the reports below.

        <stat label="Revenue" value="€1.42M" detail="+18% on last year" tone="positive" icon="eurosign"/>
        <stat label="Best quarter" value="Q3" detail="€412K"/>
        <stat label="Churn" value="2.1%" detail="+0.4 pt" tone="negative"/>

        <chart kind="bar" title="Revenue by quarter" unit="€K">
        <point label="Q1" value="318"/>
        <point label="Q2" value="341"/>
        <point label="Q3" value="412"/>
        <point label="Q4" value="349"/>
        </chart>

        <file path="~/Documents/Reports/Revenue 2026.numbers"/>
        <file path="~/Documents/Reports/Q3 Board Deck.key"/>
        <file path="~/Downloads/stripe-export-2026.csv"/>
        """

    /// Shows `screen` in a command frame of a fresh palette, sizes the card from what the views
    /// measure (as `PaletteController` does), and writes the window's content as a PNG.
    private func snapshot(
        _ name: String, _ screen: Screen, _ context: ScreenContext, title: String, dark: Bool,
        size: TextSize, select: Int = 0
    ) async throws {
        let model = PaletteModel(
            sources: [], runner: runner,
            usageURL: FileManager.default.temporaryDirectory.appending(
                path: "usage-\(UUID().uuidString).json"))
        model.textSize = size
        model.showsOnlineContent = false
        let command = RegisteredCommand(
            id: .extension("snapshot", "\(runner.count.count)"), title: title,
            icon: .symbol(name: "square.grid.2x2"))
        model.session.open(CommandRun(command, .invoked))
        #expect(await eventually { runner.count[command.id] == 1 })
        runner.runs[command.id]?.yield(.show(screen, context))
        runner.runs[command.id]?.finish()
        #expect(await eventually { model.session.frames.count == 2 && !model.top.isLoading })
        for _ in 0..<select { model.moveSelection(by: 1) }

        let host = NSHostingView(
            rootView: PaletteRootView(
                model: model, onRun: { _, _ in }, onEscape: {}, onListen: {}, onOpenLink: { _ in },
                onQueryChange: {}, onType: { _ in false }))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PaletteMetrics.windowSize(width: 600, cardHeight: 0)),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        var card: CGFloat = PaletteMetrics.unmeasuredHeight
        // Lay out, let the views report their heights, size the card; again until it holds.
        for _ in 0..<8 {
            model.cardHeight = card
            window.setContentSize(PaletteMetrics.windowSize(width: 600, cardHeight: card))
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            let measured =
                PaletteMetrics.cardHeight(
                    for: model.top, actionMenu: nil, detailHeight: model.detailHeight,
                    listTop: model.listTopHeight) ?? card
            if measured == card { break }
            card = measured
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        host.display()
        let content = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: content)
        let png = try #require(Self.composite(content, card: card, appearance: window.effectiveAppearance))
        let file = "\(name)-\(dark ? "dark" : "light")-\(size.rawValue).png"
        try png.write(to: folder.appending(path: file))
    }

    /// `content` over a stand-in for the glass: the pill and the card, filled with the window's
    /// background color, on a grey desktop.
    private static func composite(_ content: NSBitmapImageRep, card: CGFloat, appearance: NSAppearance)
        -> Data?
    {
        let (width, height) = (content.pixelsWide, content.pixelsHigh)
        guard let image = content.cgImage,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(width) / content.size.width
        var (desktop, glass) = (CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1))
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            desktop = CGColor(gray: dark ? 0.12 : 0.72, alpha: 1)
            glass = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        }
        context.setFillColor(desktop)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(glass)
        let size = content.size
        let margin = PaletteMetrics.margin
        // Core Graphics' origin is bottom left; the pill is at the top.
        let pillY = size.height - margin - PaletteMetrics.pillHeight
        let pill = CGRect(
            x: margin, y: pillY, width: size.width - 2 * margin, height: PaletteMetrics.pillHeight)
        context.addPath(
            CGPath(
                roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil
            ))
        if card > 0 {
            let rect = CGRect(
                x: margin, y: pillY - PaletteMetrics.gap - card, width: pill.width, height: card)
            let radius = PaletteMetrics.cardRadius
            context.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
}
