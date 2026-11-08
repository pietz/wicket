import Foundation
import os

extension Markup {
    /// What a parse needs to know besides the text.
    public struct Context: Sendable {
        /// Where the markup is drawn.
        public enum Placement: Sendable, Hashable {
            /// A reply or a page: everything in the catalog.
            case page
            /// A list's summary above its rows: no selectable blocks, since the arrows belong to the rows.
            case summary
        }

        public var placement: Placement
        /// The command whose output it is: stamped on rows and namespacing their ids, as in a list.
        public var origin: CommandID?
        /// Where `~/` paths lead.
        public var home: URL

        public init(
            placement: Placement = .page, origin: CommandID? = nil,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.placement = placement
            self.origin = origin
            self.home = home
        }
    }

    /// A document and the problems found on the way.
    public struct Parsed: Sendable {
        public var document: Document
        public var issues: [Issue]
    }

    /// Parses markup into a document. Never fails: what isn't valid shows as text. Keep one parser
    /// for a text that grows (a streaming answer), so a re-parse reuses the markdown it already parsed
    /// and costs only what changed.
    public struct Parser: Sendable {
        public var context: Context
        /// The prose parsed last time.
        private var cache = MarkupBuilder.Cache()

        public init(context: Context = Context()) {
            self.context = context
        }

        public mutating func parse(_ text: String) -> Parsed {
            var bytes = Array(text.utf8)
            var tail: String?
            var issues: [Issue] = []
            if bytes.count > Limits.bytes {
                let cut = bytes[..<Limits.bytes].lastIndex(of: .newline).map { $0 + 1 } ?? Limits.bytes
                let rest = bytes[cut...]
                let shown = String(decoding: rest.prefix(Limits.tailBytes), as: UTF8.self)
                tail = rest.count > Limits.tailBytes ? shown + "…" : shown
                let line = bytes[..<cut].count(where: { $0 == .newline }) + 1
                issues.append(
                    Issue(
                        line: line, kind: .limit,
                        message: "the text is longer than \(Limits.bytes / 1024) KiB; the rest shows as text")
                )
                bytes.removeSubrange(cut...)
            }
            var scanner = MarkupScanner(bytes)
            let nodes = scanner.scan()
            let builder = MarkupBuilder(bytes: bytes, context: context, cache: cache)
            var blocks = builder.blocks(nodes, MarkupBuilder.Scope())
            if let tail { blocks.append(.text(tail)) }
            cache = builder.used
            issues = scanner.issues + builder.issues + issues
            return Parsed(document: Document(blocks: blocks), issues: issues.sorted { $0.line < $1.line })
        }
    }

    /// Parses `text` into a document, logging how many problems it had by kind (never what they were,
    /// which would be content).
    public static func document(_ text: String, context: Context = Context()) -> Document {
        var parser = Parser(context: context)
        let parsed = parser.parse(text)
        log(parsed.issues)
        return parsed.document
    }

    /// Logs how many `issues` a parse had, by kind; nothing when there are none.
    public static func log(_ issues: [Issue]) {
        guard !issues.isEmpty else { return }
        let counts = Dictionary(grouping: issues, by: \.kind)
            .map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", ")
        logger.info("markup: \(issues.count, privacy: .public) issues (\(counts, privacy: .public))")
    }

    /// Every problem in `text`, for `wicket run`: an extension's markup must have none, while the
    /// same markup from an agent renders anyway.
    public static func lint(_ text: String, placement: Context.Placement = .page) -> [Issue] {
        var parser = Parser(context: Context(placement: placement))
        return parser.parse(text).issues
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "markup")
}

extension RunResult {
    /// The markup problems in what an extension sent, each as "where line N: problem": a page's
    /// markdown, a list's summary, and the pages its `detail` actions push. Empty for valid markup.
    public var markupProblems: [String] {
        var problems: [String] = []
        func lint(_ text: String, _ placement: Markup.Context.Placement, _ place: String) {
            problems += Markup.lint(text, placement: placement).map { "\(place) \($0)" }
        }
        func pushed(_ actions: [Item.Action]) {
            for case .detail(let page) in actions {
                lint(page.markdown, .page, "pushed page \"\(page.title ?? "")\" markdown")
                pushed(page.actions)
            }
        }
        guard case .show(let screen, _) = self else { return [] }
        switch screen {
        case .answer(let item):
            pushed(item.actions)
        case .list(let list):
            if let summary = list.summary { lint(summary, .summary, "summary") }
            for item in list.items { pushed(item.actions) }
        case .detail(let detail):
            lint(detail.markdown, .page, "markdown")
            pushed(detail.actions)
        }
        return problems
    }
}
