import Foundation

/// Ask AI: the built-in command that answers a question with the user's own agent CLI, streamed into
/// its frame (`AskAIRunner` in WicketHost). An ordinary `submitText` command: the question is its
/// text, it runs only when the question is submitted, so AI never sits on the keystroke path. The
/// root offers it as a fallback row for whatever was typed (`FallbackSource`); its keyword `ai`, an
/// alias or a hotkey open its frame waiting for the question.
public enum AskAI {
    public static let command = BuiltinCommand.askAI.id
    public static let title = "Ask AI"
    public static let symbol = "sparkles"
    /// Its keyword: "ai " opens its frame, and a built-in keeps its keyword against extensions.
    public static let keyword = "ai"

    static let registered = RegisteredCommand(
        id: command, title: title, icon: .symbol(name: symbol), keyword: keyword, isListed: false,
        input: .submitText, placeholder: "Ask a question", isFallback: true, feature: .askAI)

    /// The action that asks `prompt`.
    public static func action(asking prompt: String) -> Item.Action {
        .run(command: command, text: prompt, title: title)
    }
}

/// The root's fallback rows: for any non-empty query, one row per registered fallback command
/// (`RegisteredCommand.isFallback`, a `submitText` command such as Ask AI) that runs it on the query.
/// They rank in the fallback tier, so they come last and never move by habit; within it the user's
/// fallback order applies (`Ranker`, through each row's origin), else registry order. A fallback
/// whose feature is off isn't registered, so it isn't offered either.
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
