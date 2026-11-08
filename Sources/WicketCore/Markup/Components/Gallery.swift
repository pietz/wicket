import Foundation

/// One image, or a gallery of adjacent ones. Each is a target: Return opens its source, which
/// Wicket loads itself under the online-content rules.
public struct Gallery: Component {
    public struct Image: Sendable, Hashable {
        /// An https URL or a file URL.
        public var source: URL
        public var alt: String?
        public var caption: String?
        /// The selectable row it is.
        public var item: Item
    }

    public var images: [Image]

    public static let tags = [
        Markup.Tag(
            "image", aliases: ["img"],
            [
                Markup.Attribute("src", .source, required: true, "An https URL or a local path."),
                Markup.Attribute("alt", "What it shows, for VoiceOver and Copy Answer."),
                Markup.Attribute("caption", "A line under it."),
            ], focus: .always, icon: "photo", limit: 20, grouping: "Adjacent images form a gallery.",
            use: "A picture that helps: a product, a person, a screenshot.")
    ]

    public static let example = (
        markup: #"<image src="https://upload.wikimedia.org/keanu.jpg" alt="Keanu Reeves" caption="2019"/>"#,
        text: "Keanu Reeves · 2019 · https://upload.wikimedia.org/keanu.jpg"
    )

    public static func make(_ build: Markup.Build) -> Gallery? {
        guard let subject = build.source("src") else { return nil }
        let source: URL =
            switch subject {
            case .file(let url), .url(let url): url
            }
        let item = build.item(
            subject: subject, id: "image:" + subject.id, title: build.text("alt"),
            subtitle: build.text("caption"),
            icon: "photo")
        return Gallery(images: [
            Image(source: source, alt: build.text("alt"), caption: build.text("caption"), item: item)
        ])
    }

    public func text(home: URL) -> String {
        images.map { Document.line($0.alt, $0.caption, $0.item.subject?.location(home: home)) }.joined(
            separator: "\n")
    }

    public var targets: [Item] { images.map(\.item) }

    public func joining(_ next: Gallery) -> Gallery? { Gallery(images: images + next.images) }
}
