import Foundation

// The validated construction context shared by markup components when building document nodes.

extension Markup {
    /// What a component's `make` gets: the element being built, its validated attributes, and the
    /// shared machinery for its content and its rows. Only attributes its tag declares can be read.
    public struct Build {
        let builder: MarkupBuilder
        let element: Element
        /// The element's tag (never an alias).
        public let tag: Tag
        let values: [String: String]
        let scope: MarkupBuilder.Scope

        /// The tag being built, for a component with several.
        public var name: String { tag.name }
        /// Where `~/` paths lead.
        public var home: URL { builder.context.home }
        /// Where the markup is drawn.
        public var placement: Context.Placement { builder.context.placement }

        /// An attribute's value, nil if it was absent or invalid.
        public func text(_ name: String) -> String? {
            assert(tag.attribute(name) != nil, "<\(tag.name)> declares no \(name)")
            return values[name]
        }

        public func number(_ name: String) -> Double? { text(name).flatMap(Double.init) }

        public func tone() -> Document.Tone? { text("tone").flatMap(Document.Tone.init) }

        /// The `href` or `path` the element targets. In a summary, whose arrows belong to the rows,
        /// it has none.
        public func target() -> Item.Subject? {
            var subject: Item.Subject?
            if tag.attribute("href") != nil, let href = text("href") {
                subject = MarkupBuilder.link(href)
            } else if tag.attribute("path") != nil, let path = text("path") {
                subject = builder.file(path)
            }
            if subject != nil, placement == .summary {
                issue(.misplacedTag, "<\(tag.name)> in a summary can't have a target; it is ignored")
                return nil
            }
            return subject
        }

        /// A `.source` attribute as a subject: an https URL or a file.
        public func source(_ name: String) -> Item.Subject? {
            text(name).flatMap(builder.source)
        }

        /// A selectable row about `subject` (or a plain one), deriving what it leaves out as a list's
        /// row would, its id unique in the document.
        public func item(
            subject: Item.Subject?, id: String? = nil, title: String?, subtitle: String? = nil,
            icon: String? = nil, accessory: String? = nil, actions: [Item.Action] = []
        ) -> Item {
            builder.item(
                subject: subject, id: id, title: title, subtitle: subtitle,
                icon: icon.map { .symbol(name: $0) },
                accessory: accessory, actions: actions, defaultIcon: tag.icon ?? "doc")
        }

        /// The element's content as blocks, one level deeper.
        public func blocks() -> [Document.Block] { builder.blocks(element.children, inner) }

        /// Each piece of content as its own blocks: a child tag of this one (`<column>`) gives its
        /// content, anything else is one piece. Blank text gives none.
        public func pieces(of child: String) -> [[Document.Block]] {
            element.children.compactMap { node in
                if builder.isBlank(node) { return nil }
                if case .element(let element) = node, let (tag, _) = Markup.tags[element.written],
                    tag.name == child
                {
                    _ = builder.values(element, tag)
                    return builder.blocks(element.children, inner)
                }
                return builder.blocks([node], inner)
            }
        }

        /// The child tags named `child` (a chart's points), each to read like this element; anything
        /// else inside is ignored, with an issue. A child missing a required attribute is left out.
        public func children(_ child: String) -> [Build] {
            var children: [Build] = []
            for node in element.children where !builder.isBlank(node) {
                guard case .element(let element) = node, let (tag, _) = Markup.tags[element.written],
                    tag.name == child
                else {
                    issue(.ignored, "only <\(child)> belongs in <\(self.tag.name)>; the rest is ignored")
                    continue
                }
                if let values = builder.values(element, tag) {
                    children.append(
                        Build(builder: builder, element: element, tag: tag, values: values, scope: inner))
                }
            }
            return children
        }

        /// The text between the tags, trimmed, its lines joined by spaces.
        public func body() -> String {
            builder.body(element).split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }.joined(separator: " ")
        }

        /// The markdown between the tags.
        public func markdown() -> Document.Markdown {
            let text = MarkupBuilder.dedented(builder.body(element))
            let chunks = builder.prose(text, line: element.line, inner)
            return Document.Markdown(
                source: text.trimmingCharacters(in: .whitespacesAndNewlines), blocks: chunks.flatMap(\.blocks)
            )
        }

        /// Notes a problem with this element.
        public func issue(_ kind: Issue.Kind, _ message: String) { builder.issue(element, kind, message) }

        private var inner: MarkupBuilder.Scope {
            MarkupBuilder.Scope(
                depth: scope.depth + (tag.isLayout ? 1 : 0), ancestors: scope.ancestors + [tag.name])
        }
    }
}
