import Foundation

/// Up to three things side by side. Each child is a column, or each `<column>` when several blocks
/// share one. Columns don't nest; past the limit, the rest is stacked in the last column.
public struct Columns: Component {
    public var columns: [[Document.Block]]

    public static let limit = 3

    public static let tags = [
        Markup.Tag(
            "columns", body: .blocks, layout: true, nests: false,
            use:
                "Up to \(limit) things side by side, to compare them. Each child, or each `<column>`, is a column."
        ),
        Markup.Tag(
            "column", body: .blocks, role: .child(of: "columns"),
            use: "Optional, inside `<columns>`: puts several blocks in one column."),
    ]

    public static let example = (
        markup: """
        <columns>
        <stat value="7°C" label="Now"/>
        <column>
        <fact label="Wind" value="24 km/h W"/>
        <fact label="Rain" value="40%"/>
        </column>
        </columns>
        """,
        text: "Now: 7°C\n\nWind: 24 km/h W\nRain: 40%"
    )

    public static func make(_ build: Markup.Build) -> Columns? {
        var columns = build.pieces(of: "column")
        guard !columns.isEmpty else { return nil }
        if columns.count > limit {
            build.issue(.limit, "more than \(limit) columns; the rest are stacked in the last")
            columns[limit - 1] = columns[(limit - 1)...].flatMap { $0 }
            columns.removeSubrange(limit...)
        }
        return Columns(columns: columns)
    }

    public func text(home: URL) -> String {
        columns.map { Document.text($0, home: home) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var targets: [Item] { columns.flatMap(Document.targets) }
}
