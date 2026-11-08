import Foundation

/// The root's fallback rows: for any non-empty query, one row per registered fallback command
/// (`RegisteredCommand.isFallback`, a `submitText` command such as Run Agent) that runs it on the query.
/// They rank in the fallback tier, so they come last, in the order given here (`Ranker`): registry
/// order, which for built-ins is the app's table (Run Agent, then web search). Habit never moves them.
/// A fallback whose feature is off isn't registered, so it isn't offered either.
@MainActor
public struct FallbackSource: ResultSource {
    public let id = "fallbacks"
    private let registry: CommandRegistry

    public init(_ registry: CommandRegistry) {
        self.registry = registry
    }

    public func instant(_ query: Query) -> [Item] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return registry.commands.filter { $0.isFallback && $0.input == .submitText }.map { command in
            Item(
                id: "fallback:\(command.id)", title: command.title, subtitle: text, icon: command.icon,
                relevance: .fallback, actions: [.run(command: command.id, text: text, title: command.title)],
                origin: command.id)
        }
    }
}
