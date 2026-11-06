import Foundation
import Testing

@testable import WicketCore

/// Each block as plain text, prefixed by its kind.
private func outline(_ markdown: String) -> [String] {
    MarkdownBlock.parse(markdown).map { block in
        switch block {
        case .paragraph(let text): "p " + String(text.characters)
        case .heading(let level, let text): "h\(level) " + String(text.characters)
        case .listItem(let marker, let depth, let text):
            String(repeating: "  ", count: depth) + "\(marker) " + String(text.characters)
        case .code(let code): "code " + code
        case .quote(let text): "> " + String(text.characters)
        case .table(let rows):
            "table "
                + rows.map { $0.map { String($0.characters) }.joined(separator: "|") }.joined(separator: "/")
        case .rule: "rule"
        }
    }
}

@Test func splitsMarkdownIntoBlocks() {
    let markdown = """
        ## Summary

        Raises the timeout to **30 minutes**.
        Second line.

        - Adds a test
        - Updates the docs
          - nested

        1. one
        2. two

           more of two

        > quoted

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        ---

        End.
        """
    #expect(
        outline(markdown) == [
            "h2 Summary", "p Raises the timeout to 30 minutes. Second line.", "• Adds a test",
            "• Updates the docs", "  • nested", "1. one", "2. two", " more of two", "> quoted",
            "code let x = 1", "table A|B/1|2", "rule", "p End.",
        ])
}

@Test func inlineStylesSurvive() throws {
    guard case .paragraph(let text) = MarkdownBlock.parse("a **b** [c](https://example.com)").first else {
        Issue.record("not a paragraph")
        return
    }
    #expect(text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    #expect(text.runs.contains { $0.link == URL(string: "https://example.com") })
}

@Test func plainTextStaysPlain() {
    #expect(outline("just text") == ["p just text"])
    #expect(outline("").isEmpty)
}
