import Foundation

/// A short note that must stand out, tinted by its tone, with the tone's symbol.
public struct Callout: Component {
    public var tone: Document.Tone
    public var markdown: Document.Markdown

    /// The symbol each tone shows.
    public static let symbols: [Document.Tone: String] = [
        .info: "info.circle", .positive: "checkmark.circle", .warning: "exclamationmark.triangle",
        .negative: "xmark.octagon",
    ]

    public static let tags = [
        Markup.Tag(
            "callout",
            [
                .tone(
                    "info (the default), positive, warning or negative.",
                    ["info", "positive", "warning", "negative"])
            ],
            body: .markdown, icon: "info.circle",
            use: "A short note that must stand out: a caveat, a warning, a success.")
    ]

    public static let example = (
        markup:
            #"<callout tone="warning">Design review and a dentist reminder overlap at **10:00**.</callout>"#,
        text: "Design review and a dentist reminder overlap at **10:00**."
    )

    public static func make(_ build: Markup.Build) -> Callout? {
        let markdown = build.markdown()
        guard !markdown.source.isEmpty else {
            build.issue(.missingAttribute, "<callout> needs its text; it shows as text")
            return nil
        }
        return Callout(tone: build.tone() ?? .info, markdown: markdown)
    }

    public func text(home: URL) -> String { markdown.source }
}
