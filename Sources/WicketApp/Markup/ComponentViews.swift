import SwiftUI
import WicketCore

/// The view of one markup component (`WicketCore.Component`): one file per component, registered in
/// `ComponentViews.registered` by the component's type. Adding a component is its Core file, its view
/// file and a line in each registry; nothing else names it.
@MainActor
protocol ComponentView: View {
    associatedtype Node: Component
    init(_ node: Node)
}

extension ComponentView {
    /// The component's view, if `component` is this view's node.
    static func view(for component: any Component) -> AnyView? {
        (component as? Node).map { AnyView(Self($0)) }
    }

    /// The node type this view draws.
    static var node: ObjectIdentifier { ObjectIdentifier(Node.self) }
}

/// The app's registry of component views, keyed by the component's type: the one place a document
/// node meets its view, without a switch over component types.
@MainActor
enum ComponentViews {
    /// Every component view, one per entry in `Markup.components`.
    static let registered: [any ComponentView.Type] = [
        AnswerView.self, StatsView.self, FactsView.self, RowsView.self, CalloutView.self, ColumnsView.self,
        CardView.self, GalleryView.self, ChartView.self, TimelineView.self, ProgressBarView.self,
        BadgesView.self,
    ]

    private static let views: [ObjectIdentifier: (any Component) -> AnyView?] = Dictionary(
        registered.map { ($0.node, $0.view(for:)) }, uniquingKeysWith: { first, _ in first })

    /// Whether a view draws components of `type`.
    static func draws(_ type: any Component.Type) -> Bool { views[ObjectIdentifier(type)] != nil }

    /// `component`'s registered view; one without a view shows its text, so nothing is ever lost.
    static func view(for component: any Component) -> AnyView {
        if let view = views[ObjectIdentifier(type(of: component))]?(component) { return view }
        return AnyView(Text(verbatim: component.text(home: FileManager.default.homeDirectoryForCurrentUser)))
    }
}

/// What a document's views share: the text size, which target is selected and how to run one, and
/// whether images may come from the network.
struct DocumentFocus {
    /// The selected target's id.
    var selected: String?
    /// The chord hint ("⌘3") per target id while ⌘ is held.
    var hints: [String: String] = [:]
    /// Runs a target's primary action (a click, or VoiceOver's).
    var run: @MainActor (Item) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var documentFocus = DocumentFocus()
    @Entry var textSize = TextSize.medium
    /// Whether images from the network load ("Show online content", or Load Images on this page).
    @Entry var loadsOnlineContent = true
}

extension TextSize {
    /// A size designed for small text (body 13), scaled to this step's body.
    func points(_ small: CGFloat) -> CGFloat {
        (small * bodySize / TextSize.small.bodySize).rounded()
    }

    /// How much larger this step draws than the small one, for heights and spacing.
    var scale: CGFloat { bodySize / TextSize.small.bodySize }
}

/// The semantic tones as system colors, used sparingly: a value, a badge, a bar, a callout's tint.
enum ToneStyle {
    static func color(_ tone: WicketCore.Document.Tone) -> Color {
        switch tone {
        case .info: .blue
        case .positive: .green
        case .warning: .orange
        case .negative: .red
        }
    }

    /// The tone's color, or `fallback` without one.
    static func style(_ tone: WicketCore.Document.Tone?, else fallback: some ShapeStyle) -> AnyShapeStyle {
        tone.map { AnyShapeStyle(color($0)) } ?? AnyShapeStyle(fallback)
    }
}

/// An SF Symbol a producer named, or nothing when the system has no such symbol: a made-up name
/// never shows a blank square.
struct SymbolImage: View {
    let name: String?

    var body: some View {
        if let name, Self.exists(name) {
            Image(systemName: name)
        }
    }

    private static var known: [String: Bool] = [:]

    /// Whether the system draws `name`; looked up once per name.
    static func exists(_ name: String) -> Bool {
        if let exists = known[name] { return exists }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        known[name] = exists
        return exists
    }
}

/// The quiet inset surface cards and tiles sit on: lighter than the glass in both appearances.
struct Surface: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Self.fill, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    static let fill = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.58)
        })
}

/// A selectable block of a document: the selection's highlight, a click runs it, the arrows scroll
/// to it (its id), and VoiceOver reads it as a button. A block without an item is left as it is.
struct Target: ViewModifier {
    let item: Item?
    var radius = PaletteMetrics.rowRadius
    @Environment(\.documentFocus) private var focus

    func body(content: Content) -> some View {
        if let item { selectable(content, item) } else { content }
    }

    private func selectable(_ content: Content, _ item: Item) -> some View {
        let selected = focus.selected == item.id
        return
            content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.primary.opacity(0.1))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hint = focus.hints[item.id] {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: .rect(cornerRadius: 4))
                        .padding(6)
                }
            }
            .contentShape(.rect)
            .onTapGesture { focus.run(item) }
            .id(item.id)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { focus.run(item) }
    }
}

extension View {
    func surface(radius: CGFloat) -> some View { modifier(Surface(radius: radius)) }
    func target(_ item: Item?, radius: CGFloat = PaletteMetrics.rowRadius) -> some View {
        modifier(Target(item: item, radius: radius))
    }
}

/// A group's title above it (a list's, a strip's, a timeline's): small and secondary, a heading for
/// VoiceOver.
struct GroupHeading: View {
    let title: String
    @Environment(\.textSize) private var textSize

    var body: some View {
        Text(title)
            .font(.system(size: textSize.points(11), weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
