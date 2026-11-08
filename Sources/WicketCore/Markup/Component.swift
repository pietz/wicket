import Foundation

/// One native component of Wicket's markup, self-contained: its tags, how it is built from them,
/// its text for Copy Answer and what the arrows can select in it. Its value is the document node
/// the view draws; the view is one file too, registered by type (M2).
///
/// A component is registered in `Markup.components`, and everything else (parsing, validation,
/// limits, grouping, the agent's reference, docs/markup.md, the lint, the tests) reads it from there.
public protocol Component: Sendable, Hashable {
    /// The tags it reads: its own, plus a wrapper (`<list>`) or child tags (`<point>`) that exist
    /// only for it.
    static var tags: [Markup.Tag] { get }
    /// Markup using it and that markup's Copy Answer text: the docs show it, the tests parse it.
    static var example: (markup: String, text: String) { get }
    /// The node for the element being built (one of `tags` whose role is `.node`), from its
    /// validated attributes and content. Nil shows the element as text; say why with `build.issue`.
    static func make(_ build: Markup.Build) -> Self?
    /// Its plain text, which Copy Answer copies.
    func text(home: URL) -> String
    /// What the arrows can select in it, in reading order. Each id is unique in the document.
    var targets: [Item] { get }
    /// This group with `next` added, when repetition joins them (stats into a strip); nil keeps
    /// them apart.
    func joining(_ next: Self) -> Self?
    /// The group with a wrapper's title.
    func titled(_ title: String) -> Self
}

extension Component {
    public var targets: [Item] { [] }
    public func joining(_ next: Self) -> Self? { nil }
    public func titled(_ title: String) -> Self { self }

    func isEqual(_ other: any Component) -> Bool { (other as? Self) == self }
    func joining(any next: any Component) -> (any Component)? {
        guard let next = next as? Self else { return nil }
        return joining(next)
    }
}
