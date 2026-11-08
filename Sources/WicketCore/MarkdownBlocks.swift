import Foundation

/// A detail's markdown as blocks the palette can lay out. Foundation parses the full syntax, but
/// SwiftUI's `Text` draws only inline styles (emphasis, code, links) and runs the blocks together,
/// so the blocks are split here and each is drawn on its own.
public enum MarkdownBlock: Sendable, Hashable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    /// `marker` is "•" or "3.", empty for a list item's later paragraphs; `depth` counts from 0.
    case listItem(marker: String, depth: Int, AttributedString)
    case code(String)
    case quote(AttributedString)
    /// Rows of cells, the header row first.
    case table([[AttributedString]])
    case rule

    /// Never fails: what doesn't parse stays plain text.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [.paragraph(AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        var table: (id: Int, row: Int)?
        var rows: [[AttributedString]] = []
        var markedItems = Set<Int>()

        func flushTable() {
            if table != nil { blocks.append(.table(rows)) }
            table = nil
            rows = []
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let text = AttributedString(parsed[range])
            let kinds = intent?.components ?? []

            if let cell = kinds.firstIndex(where: { if case .tableCell = $0.kind { true } else { false } }),
                case .tableCell(let column) = kinds[cell].kind,
                let tableIntent = kinds.first(where: { if case .table = $0.kind { true } else { false } }),
                case .table(let columns) = tableIntent.kind
            {
                let row = kinds[(cell + 1)...].first?.identity ?? 0
                if table?.id != tableIntent.identity { flushTable() }
                if table?.id != tableIntent.identity || table?.row != row {
                    // Empty cells have no runs, so every cell is placed by its column, blanks kept.
                    rows.append(Array(repeating: AttributedString(), count: max(columns.count, column + 1)))
                    table = (tableIntent.identity, row)
                }
                if column >= rows[rows.count - 1].count { rows[rows.count - 1].append(AttributedString()) }
                // A cell with styled text comes as several runs.
                rows[rows.count - 1][column] += text
                continue
            }
            flushTable()

            let lists = kinds.filter {
                switch $0.kind {
                case .orderedList, .unorderedList: true
                default: false
                }
            }
            var block = MarkdownBlock.paragraph(text)
            for component in kinds {
                switch component.kind {
                case .codeBlock:
                    var code = String(text.characters)
                    while code.hasSuffix("\n") { code.removeLast() }
                    block = .code(code)
                case .header(let level):
                    block = .heading(level: level, text)
                case .listItem(let ordinal):
                    guard case .paragraph = block else { break }
                    let ordered: Bool
                    if case .orderedList = lists.first?.kind { ordered = true } else { ordered = false }
                    let first = markedItems.insert(component.identity).inserted
                    let marker = first ? (ordered ? "\(ordinal)." : "•") : ""
                    block = .listItem(marker: marker, depth: max(lists.count - 1, 0), text)
                case .thematicBreak:
                    block = .rule
                case .blockQuote:
                    if case .paragraph = block { block = .quote(text) }
                default:
                    break
                }
            }
            blocks.append(block)
        }
        flushTable()
        return blocks
    }
}
