import Foundation

/// Things at a time on a rail: adjacent `<event>`s, titled by `<timeline>`. An event with an `href`
/// or `path` is a target (Return opens it); the arrows skip the others.
public struct Timeline: Component {
    public struct Event: Sendable, Hashable {
        public var time: String?
        public var end: String?
        public var title: String
        public var detail: String?
        public var target: Item?
    }

    public var title: String?
    public var events: [Event]

    public static let tags = [
        Markup.Tag(
            "event",
            [
                Markup.Attribute("time", "When, as the user reads it: 09:00, Mon, 2 Nov."),
                Markup.Attribute("end", "When it ends."),
                Markup.Attribute("title", required: true, "What happens."),
                Markup.Attribute("detail", "Where, who, how long."), .href, .path,
            ], focus: .withTarget, exclusive: ["href", "path"], grouping: "Adjacent events form a timeline.",
            use: "Something at a time: a meeting, a commit, a step."),
        Markup.Tag(
            "timeline", [.title], body: .tags(["event"]), role: .wrapper, use: "Optional: titles a timeline."),
    ]

    public static let example = (
        markup: """
        <event time="09:00" end="09:15" title="Standup" detail="Zoom" href="https://zoom.us/j/123"/>
        <event time="10:00" title="Design review" detail="Room Elbe"/>
        """,
        text: "- 09:00–09:15 · Standup · Zoom\n- 10:00 · Design review · Room Elbe"
    )

    public static func make(_ build: Markup.Build) -> Timeline? {
        let title = build.text("title")!
        let target = build.target().map {
            build.item(
                subject: $0, title: title, subtitle: build.text("detail"), accessory: build.text("time"))
        }
        return Timeline(events: [
            Event(
                time: build.text("time"), end: build.text("end"), title: title, detail: build.text("detail"),
                target: target)
        ])
    }

    public func text(home: URL) -> String {
        let lines = events.map { event in
            "- "
                + Document.line(
                    [event.time, event.end].compactMap { $0 }.joined(separator: "–"), event.title,
                    event.detail)
        }
        return ([title].compactMap { $0 } + lines).joined(separator: "\n")
    }

    public var targets: [Item] { events.compactMap(\.target) }

    public func joining(_ next: Timeline) -> Timeline? {
        title == nil && next.title == nil ? Timeline(events: events + next.events) : nil
    }

    public func titled(_ title: String) -> Timeline { Timeline(title: title, events: events) }
}
