import Foundation

/// What the user has said so far while Wicket listens: the segments the recognizer finalized, then
/// the volatile tail it may still revise. Each volatile result replaces the tail; a final one
/// replaces it and joins the finalized text.
public struct Transcript: Equatable, Sendable {
    public private(set) var finalized = ""
    public private(set) var volatile = ""

    public init() {}

    public mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    /// The whole transcript, segments separated by one space.
    public var text: String { Self.join(finalized, volatile) }

    /// What a transcript puts into the search field: trimmed, without a trailing full stop, so
    /// "Safari." still matches the app. A question mark stays, since it tells Wicket the text is a
    /// request.
    public static func searchText(_ spoken: String) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "." || last == "。" {
            text.removeLast()
        }
        return text
    }

    private static func join(_ head: String, _ tail: String) -> String {
        let head = head.trimmingCharacters(in: .whitespaces)
        let tail = tail.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
