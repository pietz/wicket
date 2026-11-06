import Foundation

/// Ask AI: the built-in command that answers a question with the user's own agent CLI, streamed into
/// its frame (`AskAIRunner` in WicketHost). The root offers it for whatever was typed, as a fallback
/// row (`AskAISource`); nothing runs until the user picks the row, so AI never sits on the keystroke
/// path. The question travels as the run's `prompt` argument.
public enum AskAI {
    public static let command = BuiltinCommand.askAI.id
    public static let title = "Ask AI"
    public static let symbol = "sparkles"
    /// Typed before the question in the root ("ai capital of peru"), it lifts the row to the top.
    public static let prefix = "ai"
    static let promptKey = "prompt"

    /// The action that asks `prompt`.
    public static func action(asking prompt: String) -> Item.Action {
        .run(command: command, args: [promptKey: .string(prompt)], title: title)
    }

    /// The question an invocation asks, if it names one.
    public static func prompt(of invocation: Invocation) -> String? {
        guard case .string(let prompt) = invocation.args?[promptKey] else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The root's "Ask AI" row: for any non-empty query, one static row in the fallback tier (so it
/// comes last, never moves by habit, and takes its place in the user's fallback order through its
/// origin). With the `ai` prefix and a question after it, the row asks only the question and ranks
/// as an exact match, at the top; the user's alias for Ask AI (settings.json `commands`) works the
/// same and ranks in the alias tier. A prefix and a space with no question yet (what Ask AI's hotkey
/// types) shows the row at the top waiting for one.
///
/// Not a registry keyword: a keyword opens its command's frame as soon as the space is typed, and
/// Ask AI must neither run on an empty question (a once frame) nor on every keystroke (a live one).
public struct AskAISource: ResultSource {
    public let id = "ask-ai"
    private let registry: CommandRegistry?

    /// `registry` gives the user's alias for Ask AI, if any.
    public init(registry: CommandRegistry? = nil) {
        self.registry = registry
    }

    public func instant(_ query: Query) -> [Item] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var row = Item(
            id: "ask-ai:ask", title: AskAI.title, subtitle: text, icon: .symbol(name: AskAI.symbol),
            relevance: .fallback, actions: [AskAI.action(asking: text)], origin: AskAI.command)
        let alias = registry?.alias(of: AskAI.command)
        if let (prefix, question) = Self.prefixed(
            query.text, prefixes: [AskAI.prefix] + (alias.map { [$0] } ?? []))
        {
            row.relevance = prefix == AskAI.prefix ? .exact : .alias
            row.subtitle = question ?? "Type a question"
            row.actions = question.map { [AskAI.action(asking: $0)] } ?? []
        }
        return [row]
    }

    /// The prefix `text` starts with (ignoring case) and a space, and the question after it (nil
    /// while there is none yet).
    static func prefixed(_ text: String, prefixes: [String] = [AskAI.prefix]) -> (
        prefix: String, question: String?
    )? {
        let text = text.drop(while: \.isWhitespace)
        guard let space = text.firstIndex(where: \.isWhitespace) else { return nil }
        let word = text[..<space].lowercased()
        guard let prefix = prefixes.first(where: { $0.lowercased() == word }) else { return nil }
        let rest = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix, rest.isEmpty ? nil : rest)
    }
}
