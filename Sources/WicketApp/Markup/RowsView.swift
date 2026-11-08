import SwiftUI
import WicketCore

/// `<file>`, `<url>` and `<item>` rows under their list's title: the palette's own row, each a
/// target, its icon from the icon cache and a file's date read off the main actor.
struct RowsView: ComponentView {
    let node: Rows
    @Environment(\.textSize) private var textSize
    @Environment(\.documentFocus) private var focus

    init(_ node: Rows) { self.node = node }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * textSize.scale) {
            if let title = node.title { GroupHeading(title: title) }
            VStack(spacing: PaletteMetrics.rowSpacing) {
                ForEach(node.items, id: \.id) { item in
                    ResultRow(
                        item: item, isProminent: false, isSelected: focus.selected == item.id,
                        hint: focus.hints[item.id], scale: textSize.scale
                    )
                    .contentShape(.rect)
                    .onTapGesture { focus.run(item) }
                    .id(item.id)
                    .accessibilityAction { focus.run(item) }
                }
            }
            // The rows' icons line up with the text around them; their highlight reaches past it.
            .padding(.horizontal, -10)
        }
    }
}
