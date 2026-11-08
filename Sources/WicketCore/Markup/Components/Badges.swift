import Foundation

/// Short status labels in a row: adjacent `<badge>`s. A badge starts its own line; inside a
/// paragraph it is text.
public struct Badges: Component {
    public struct Badge: Sendable, Hashable {
        public var text: String
        public var tone: Document.Tone?
    }

    public var badges: [Badge]

    public static let tags = [
        Markup.Tag(
            "badge", [.tone("Colors it.")], body: .text, grouping: "Adjacent badges form a row.",
            use: "A short status label, on its own line.")
    ]

    public static let example = (
        markup: """
        <badge tone="positive">Free 11:00 to 15:00</badge>
        <badge>4 events</badge>
        """,
        text: "Free 11:00 to 15:00 · 4 events"
    )

    public static func make(_ build: Markup.Build) -> Badges? {
        let text = build.body()
        guard !text.isEmpty else {
            build.issue(
                .missingAttribute, "<badge> needs its text, as in <badge>Paid</badge>; it shows as text")
            return nil
        }
        return Badges(badges: [Badge(text: text, tone: build.tone())])
    }

    public func text(home: URL) -> String { badges.map(\.text).joined(separator: " · ") }

    public func joining(_ next: Badges) -> Badges? { Badges(badges: badges + next.badges) }
}
