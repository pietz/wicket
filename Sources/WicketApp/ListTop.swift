import AppKit
import SwiftUI
import WicketCore

/// How a list's summary and facts fit above its rows (docs/extensions.md, "Level 2: a list"): the
/// summary shows whole when it fits beside the rows, else its first three lines with "more", and
/// Read Summary (⌘K) pushes it whole as a page with every fact; up to four facts show in the strip.
@MainActor
enum SummaryLayout {
    /// The lines a clipped summary shows.
    static let clippedLines = 3
    /// The facts the strip shows; more are on the Read Summary page.
    static let factsShown = 4
    /// The height of a line of the summary's text (13 pt).
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13))

    /// The most lines a summary shows whole beside `rows` rows: three, or with at most three rows
    /// also the room the rows leave under the eight-row card.
    static func lineLimit(rows: Int, lineHeight: CGFloat = lineHeight) -> Int {
        guard rows <= clippedLines else { return clippedLines }
        let spare =
            CGFloat(PaletteMetrics.maxRows - max(rows, 1))
            * (PaletteMetrics.rowHeight + PaletteMetrics.rowSpacing)
        return clippedLines + Int(spare / lineHeight)
    }

    /// Whether a summary of `lines` lines is clipped above `rows` rows.
    static func isClipped(lines: Int, rows: Int, lineHeight: CGFloat = lineHeight) -> Bool {
        lines > lineLimit(rows: rows, lineHeight: lineHeight)
    }

    /// The lines a text laid out `height` tall takes.
    static func lines(height: CGFloat, lineHeight: CGFloat = lineHeight) -> Int {
        Int((height / lineHeight).rounded())
    }

    /// Whether `listing` has more to show than its top does: a clipped summary, or facts past the
    /// strip's.
    static func hasMore(_ listing: Listing, summaryClipped: Bool) -> Bool {
        summaryClipped || listing.facts.count > factsShown
    }

    /// The summary's inline markdown (emphasis, code, links); its line breaks kept.
    static func text(_ summary: String) -> AttributedString {
        (try? AttributedString(
            markdown: summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(summary)
    }
}

/// Read Summary: the host's screen action that pushes a list's whole summary as a page, with all
/// its facts as the page's metadata. The palette adds it to the screen's actions when the list has
/// more than its top shows (`SummaryLayout.hasMore`), so it is never on the wire nor inherited by
/// the page it pushes.
enum ReadSummary {
    static let title = "Read Summary"
    private static let pageTitle = "Summary"

    static func action(for listing: Listing) -> Item.Action {
        .detail(Detail(title: pageTitle, markdown: listing.summary ?? "", metadata: listing.facts))
    }

    /// Whether `action`, one of the screen's, is Read Summary.
    static func `is`(_ action: Item.Action) -> Bool {
        if case .detail(let detail) = action { detail.title == pageTitle } else { false }
    }
}

extension Listing {
    /// Whether the list has a top to draw above its rows.
    var hasTop: Bool { summary != nil || !facts.isEmpty }
}

extension Frame {
    /// The list the frame shows, if it shows one (not the root's results).
    var listing: Listing? {
        guard case .screen(let screen) = content, case .list(let listing)? = screen.screen else { return nil }
        return listing
    }
}

/// A list's summary and facts, pinned above its rows and not selectable. It reports its height
/// and whether the summary is clipped once the summary's lines are known, so the card is never
/// sized for a summary that is about to be cut.
struct ListTop: View {
    let listing: Listing
    /// Pushes the whole summary (the "more" after a clipped one).
    let onReadSummary: () -> Void
    /// The top's height and whether its summary is clipped.
    let onMeasure: (CGFloat, Bool) -> Void
    /// The summary's lines laid out unclipped at the top's width; nil until laid out.
    @State private var lines: Int?
    @State private var height: CGFloat?

    private var clipped: Bool {
        lines.map { SummaryLayout.isClipped(lines: $0, rows: listing.items.count) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = listing.summary {
                summaryView(SummaryLayout.text(summary))
            }
            if !listing.facts.isEmpty {
                FactsStrip(facts: Array(listing.facts.prefix(SummaryLayout.factsShown)))
                    .padding(.horizontal, 20)
                    .padding(.top, listing.summary == nil ? 14 : 10)
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .onChange(of: Measure(height: height, lines: lines, clipped: clipped), initial: true) { _, measure in
            guard let height = measure.height, listing.summary == nil || measure.lines != nil else { return }
            onMeasure(height, measure.clipped)
        }
    }

    private struct Measure: Equatable {
        let height: CGFloat?
        let lines: Int?
        let clipped: Bool
    }

    /// The summary, its first three lines and "more" when clipped. A hidden copy laid out whole at
    /// the same width counts its lines; until it has, the summary shows clipped without "more".
    private func summaryView(_ text: AttributedString) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(text)
                .lineLimit(lines == nil || clipped ? SummaryLayout.clippedLines : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                            lines = SummaryLayout.lines(height: $0)
                        }
                }
            if clipped {
                Button("more", action: onReadSummary)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .accessibilityLabel(ReadSummary.title)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilitySortPriority(1)
    }
}

/// Up to four labelled values side by side, with a hairline between them.
private struct FactsStrip: View {
    let facts: [Detail.Metadata]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider().frame(height: 32) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilitySortPriority(1)
    }
}

/// A section's title above its first row: small and secondary, a heading for VoiceOver, never
/// selected (the arrows move through rows only).
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(height: PaletteMetrics.sectionHeaderHeight)
            .accessibilityAddTraits(.isHeader)
    }
}
