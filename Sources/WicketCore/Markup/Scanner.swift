import Foundation

// First-pass markup scanning: block-position tags, opaque code and recoverable syntax issues.

extension Markup {
    /// A problem in markup, by line. An agent's reply renders anyway and only the counts are logged;
    /// `wicket run` reports each one of an extension's as an error.
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            /// Not a Wicket tag (real HTML such as `<b>`, a misspelling): it shows as text.
            case unknownTag
            /// A Wicket tag where it can't be: inside a paragraph, outside its parent, too deep.
            case misplacedTag
            /// A tag or attribute written by an alias (`<img>`, `type`).
            case alias
            case unknownAttribute
            case duplicateAttribute
            case invalidValue
            /// A required attribute is missing or invalid, so the tag shows as text.
            case missingAttribute
            case unclosed
            case strayClose
            /// Something past a limit, shown as text or dropped.
            case limit
            /// Content a tag can't hold (text inside a chart), dropped.
            case ignored
        }

        public var line: Int
        public var kind: Kind
        public var message: String

        public var description: String { "line \(line): \(message)" }
    }

    /// A Wicket tag as written, before the catalog's rules are applied to it.
    struct Element {
        var tag: Tag
        /// The name as written, which may be an alias.
        var written: String
        var attributes: [(name: String, value: String)]
        var children: [Node] = []
        var line: Int
        /// Byte offsets of its source: from its `<` to the end of its closing tag, or where it was
        /// closed for it.
        var start: Int
        var end: Int
    }

    enum Node {
        case element(Element)
        /// Source bytes outside any tag (prose, code, tags that aren't Wicket's).
        case text(Range<Int>)
    }
}

/// The first pass: a line scanner that finds Wicket's tags where a block may start (a line's start,
/// or right after another tag), and leaves everything else as text ranges for the markdown parser.
/// Fenced code, and indented code at the top level, are never scanned for tags.
struct MarkupScanner {
    private let bytes: [UInt8]
    private(set) var issues: [Markup.Issue] = []
    private var root: [Markup.Node] = []
    /// Elements whose closing tag hasn't come yet, outermost first.
    private var open: [Markup.Element] = []
    private var line = 1
    private var fence: (byte: UInt8, count: Int)?
    private var previousBlank = true
    private var inIndentedCode = false
    /// The next text starts a node of its own: top-level prose is cut where a new markdown block
    /// surely starts, so each piece is parsed (and cached) on its own.
    private var split = false

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func scan() -> [Markup.Node] {
        var position = 0
        while position < bytes.count { position = scanLine(position) }
        while let element = open.last {
            unclosed(element, by: nil)
            close(open.count - 1, at: bytes.count)
        }
        return root
    }

    // MARK: Lines

    private mutating func scanLine(_ start: Int) -> Int {
        let end = lineEnd(start)
        let next = Swift.min(end + 1, bytes.count)
        if let open = fence {
            if closesFence(start, end, open) { fence = nil }
            return wholeLine(start..<next)
        }
        var first = start
        var indent = 0
        while first < end, bytes[first] == .space || bytes[first] == .tab {
            indent += bytes[first] == .tab ? 4 - indent % 4 : 1
            first += 1
        }
        if first == end || (first + 1 == end && bytes[first] == .cr) {
            previousBlank = true
            inIndentedCode = false
            return wholeLine(start..<next)
        }
        let atTop = open.isEmpty
        defer { previousBlank = false }
        if indent < 4 || !atTop, let opened = opensFence(first, end) {
            fence = opened
            return wholeLine(start..<next)
        }
        // Indented code: only at the top level, since inside a tag indentation is layout.
        if atTop, indent >= 4, previousBlank || inIndentedCode {
            inIndentedCode = true
            return wholeLine(start..<next)
        }
        inIndentedCode = false
        // After a blank line, an unindented line that doesn't continue a list starts a new block.
        split = atTop && previousBlank && indent == 0 && !startsListItem(first, end)
        defer { split = false }
        return scanBlocks(from: first, textStart: start)
    }

    private func startsListItem(_ first: Int, _ end: Int) -> Bool {
        let byte = bytes[first]
        if byte == UInt8(ascii: "-") || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "+") {
            return first + 1 == end || bytes[first + 1].isSpace
        }
        var i = first
        while i < end, bytes[i].isDigit { i += 1 }
        guard i > first, i < end, bytes[i] == UInt8(ascii: ".") || bytes[i] == UInt8(ascii: ")") else {
            return false
        }
        return i + 1 == end || bytes[i + 1].isSpace
    }

    /// Scans from `start`, where a block may start, to the end of its line (later, if a tag spans
    /// lines); text before `start` on the line is its indentation, kept for the prose. Returns the
    /// next line's start.
    private mutating func scanBlocks(from start: Int, textStart lineStart: Int) -> Int {
        var cursor = start
        var textStart = lineStart
        while true {
            let end = lineEnd(cursor)
            let next = Swift.min(end + 1, bytes.count)
            if cursor >= end || (cursor + 1 == end && bytes[cursor] == .cr) {
                line += 1
                return next
            }
            let inText = open.last.map { $0.tag.body == .text || $0.tag.body == .markdown } ?? false
            guard bytes[cursor] == .less, let token = tag(at: cursor) else {
                // Text, up to a closing tag of an open element on the same line (`Paid</badge>`).
                guard let close = closingTag(from: cursor, to: end) else {
                    return wholeLine(prose(textStart..<next))
                }
                text(prose(textStart..<close.start))
                _ = closeTag(close.token)
                cursor = skipSpaces(close.token.end)
                textStart = cursor
                continue
            }
            if token.closing {
                // A void tag's closing tag (`<img …></img>`) is habit, not a mistake.
                if token.tag.body != .none, !closeTag(token) {
                    issue(.strayClose, "</\(token.written)> closes nothing")
                }
            } else if inText {
                // Text holds no tags: another tag ends it, and is read again outside it.
                unclosed(open[open.count - 1], by: nil)
                close(open.count - 1, at: cursor)
                continue
            } else {
                let element = Markup.Element(
                    tag: token.tag, written: token.written, attributes: token.attributes, line: line,
                    start: cursor, end: token.end)
                if token.selfClosing || token.tag.body == .none {
                    append(.element(element))
                } else {
                    open.append(element)
                }
            }
            line += token.lines
            cursor = skipSpaces(token.end)
            textStart = cursor
            split = false
        }
    }

    /// The first closing tag of an open element in `start..<end`, with where it starts.
    private func closingTag(from start: Int, to end: Int) -> (start: Int, token: Token)? {
        guard !open.isEmpty else { return nil }
        var probe = start + 1
        while probe + 1 < end {
            if bytes[probe] == .less, bytes[probe + 1] == .slash, let token = tag(at: probe),
                open.contains(where: { $0.tag.name == token.tag.name })
            {
                return (probe, token)
            }
            probe += 1
        }
        return nil
    }

    // MARK: Tree

    /// Appends text, joining it to the text just before it.
    private mutating func text(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        func join(_ nodes: inout [Markup.Node]) {
            if case .text(let previous)? = nodes.last, previous.upperBound == range.lowerBound {
                nodes[nodes.count - 1] = .text(previous.lowerBound..<range.upperBound)
            } else {
                nodes.append(.text(range))
            }
        }
        if split, open.isEmpty {
            split = false
            root.append(.text(range))
        } else if open.isEmpty {
            join(&root)
        } else {
            join(&open[open.count - 1].children)
        }
    }

    /// Prose on the current line: notes each `<name` in it, a Wicket tag that doesn't start a block
    /// or a tag Wicket doesn't know (real HTML, a misspelling), since both show as text. Code spans
    /// are skipped, and so is text a tag reads as plain (a badge's) or ignores (a chart's).
    private mutating func prose(_ range: Range<Int>) -> Range<Int> {
        if let parent = open.last?.tag, parent.body != .blocks, parent.body != .markdown,
            parent.role != .wrapper
        {
            return range
        }
        var code = false
        var i = range.lowerBound
        while i < range.upperBound {
            let byte = bytes[i]
            i += 1
            if byte == .backtick { code.toggle() }
            guard !code, byte == .less, i < range.upperBound, bytes[i].isLetter else { continue }
            var end = i
            while end < range.upperBound, bytes[end].isLetter || bytes[end].isDigit || bytes[end] == .dash {
                end += 1
            }
            guard
                end == range.upperBound || bytes[end].isSpace || bytes[end] == .greater
                    || bytes[end] == .slash
            else { continue }
            let name = String(decoding: bytes[i..<end], as: UTF8.self).lowercased()
            if Markup.tags[name] == nil {
                issue(.unknownTag, "<\(name)> isn't a Wicket tag; it shows as text")
            } else {
                issue(.misplacedTag, "<\(name)> must start its own line; here it shows as text")
            }
        }
        return range
    }

    /// Appends the rest of a line as text; returns the next line's start.
    private mutating func wholeLine(_ range: Range<Int>) -> Int {
        text(range)
        line += 1
        return range.upperBound
    }

    private mutating func append(_ node: Markup.Node) {
        if open.isEmpty { root.append(node) } else { open[open.count - 1].children.append(node) }
    }

    /// Closes the innermost open element `token` closes, and any opened inside it; false if none.
    private mutating func closeTag(_ token: Token) -> Bool {
        guard let index = open.lastIndex(where: { $0.tag.name == token.tag.name }) else { return false }
        for inner in open[(index + 1)...] { unclosed(inner, by: token.written) }
        close(index, at: token.end)
        return true
    }

    /// Closes the open element at `index` (and those inside it) where its source ends.
    private mutating func close(_ index: Int, at end: Int) {
        while open.count > index {
            var element = open.removeLast()
            element.end = end
            append(.element(element))
        }
    }

    private mutating func unclosed(_ element: Markup.Element, by parent: String?) {
        let why = parent.map { "; </\($0)> closes it" } ?? ""
        issues.append(
            .init(
                line: element.line, kind: .unclosed,
                message: "<\(element.written)> on line \(element.line) isn't closed\(why)"))
    }

    private mutating func issue(_ kind: Markup.Issue.Kind, _ message: String) {
        issues.append(.init(line: line, kind: kind, message: message))
    }

    // MARK: Tokens

    private struct Token {
        var tag: Markup.Tag
        var written: String
        var closing: Bool
        var selfClosing = false
        var attributes: [(name: String, value: String)] = []
        /// The offset after its `>`.
        var end: Int
        /// The line breaks inside it.
        var lines = 0
    }

    /// The Wicket tag starting at `start`, nil if there is none (any other `<…` is text).
    private func tag(at start: Int) -> Token? {
        var i = start + 1
        let closing = i < bytes.count && bytes[i] == .slash
        if closing { i += 1 }
        let nameStart = i
        guard i < bytes.count, bytes[i].isLetter else { return nil }
        while i < bytes.count, bytes[i].isLetter || bytes[i].isDigit || bytes[i] == .dash { i += 1 }
        let written = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
        guard let tag = Markup.tags[written]?.tag, i < bytes.count,
            bytes[i].isSpace || bytes[i] == .slash || bytes[i] == .greater
        else { return nil }
        if closing {
            while i < bytes.count, bytes[i] == .space || bytes[i] == .tab { i += 1 }
            guard i < bytes.count, bytes[i] == .greater else { return nil }
            return Token(tag: tag, written: written, closing: true, end: i + 1)
        }
        var token = Token(tag: tag, written: written, closing: false, end: i)
        while true {
            while i < bytes.count, bytes[i].isSpace {
                if bytes[i] == .newline { token.lines += 1 }
                i += 1
            }
            // A tag spans a few lines at most; past that it is text, not a runaway.
            guard i < bytes.count, token.lines <= 16 else { return nil }
            if bytes[i] == .greater {
                token.end = i + 1
                return token
            }
            if bytes[i] == .slash, i + 1 < bytes.count, bytes[i + 1] == .greater {
                token.selfClosing = true
                token.end = i + 2
                return token
            }
            let nameStart = i
            while i < bytes.count, !bytes[i].isSpace, bytes[i] != .equals, bytes[i] != .greater,
                bytes[i] != .quote, bytes[i] != .apostrophe,
                !(bytes[i] == .slash && i + 1 < bytes.count && bytes[i + 1] == .greater)
            {
                i += 1
            }
            guard i > nameStart else { return nil }
            let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
            while i < bytes.count, bytes[i] == .space || bytes[i] == .tab { i += 1 }
            var value = ""
            if i < bytes.count, bytes[i] == .equals {
                i += 1
                while i < bytes.count, bytes[i] == .space || bytes[i] == .tab { i += 1 }
                guard i < bytes.count else { return nil }
                if bytes[i] == .quote || bytes[i] == .apostrophe {
                    let quote = bytes[i]
                    i += 1
                    let valueStart = i
                    while i < bytes.count, bytes[i] != quote {
                        if bytes[i] == .newline { token.lines += 1 }
                        i += 1
                    }
                    guard i < bytes.count else { return nil }
                    value = Self.unescaped(bytes[valueStart..<i])
                    i += 1
                } else {
                    let valueStart = i
                    while i < bytes.count, !bytes[i].isSpace, bytes[i] != .greater,
                        !(bytes[i] == .slash && i + 1 < bytes.count && bytes[i + 1] == .greater)
                    {
                        i += 1
                    }
                    value = Self.unescaped(bytes[valueStart..<i])
                }
            }
            token.attributes.append((name, value))
        }
    }

    /// `bytes` as text, with XML's five escapes and numeric character references decoded.
    static func unescaped(_ bytes: ArraySlice<UInt8>) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard bytes.contains(.ampersand) else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest.dropFirst()
                continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semicolon]
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
            var decoded = named[String(entity)]
            if decoded == nil, entity.first == "#" {
                let digits = entity.dropFirst()
                let scalar =
                    digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                decoded = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if let decoded {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }

    // MARK: Bytes

    private func lineEnd(_ start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] != .newline { i += 1 }
        return i
    }

    private func skipSpaces(_ start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] == .space || bytes[i] == .tab { i += 1 }
        return i
    }

    private func opensFence(_ first: Int, _ end: Int) -> (byte: UInt8, count: Int)? {
        let byte = bytes[first]
        guard byte == .backtick || byte == .tilde else { return nil }
        var i = first
        while i < end, bytes[i] == byte { i += 1 }
        let count = i - first
        guard count >= 3 else { return nil }
        // A backtick fence's info string has no backticks.
        if byte == .backtick, bytes[i..<end].contains(.backtick) { return nil }
        return (byte, count)
    }

    private func closesFence(_ start: Int, _ end: Int, _ fence: (byte: UInt8, count: Int)) -> Bool {
        var i = start
        while i < end, bytes[i] == .space || bytes[i] == .tab { i += 1 }
        let first = i
        while i < end, bytes[i] == fence.byte { i += 1 }
        guard i - first >= fence.count else { return false }
        while i < end, bytes[i].isSpace { i += 1 }
        return i == end
    }
}

extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let less = UInt8(ascii: "<")
    static let greater = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let equals = UInt8(ascii: "=")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let dash = UInt8(ascii: "-")
    static let backtick = UInt8(ascii: "`")
    static let tilde = UInt8(ascii: "~")
    static let ampersand = UInt8(ascii: "&")

    var isLetter: Bool { (self >= 65 && self <= 90) || (self >= 97 && self <= 122) }
    var isDigit: Bool { self >= 48 && self <= 57 }
    var isSpace: Bool { self == .space || self == .tab || self == .newline || self == .cr }
}
