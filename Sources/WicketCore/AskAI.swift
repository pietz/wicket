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
/// as an exact match, at the top.
///
/// Not a registry keyword: a keyword opens its command's frame as soon as the space is typed, and
/// Ask AI must neither run on an empty question (a once frame) nor on every keystroke (a live one).
public struct AskAISource: ResultSource {
    public let id = "ask-ai"

    public init() {}

    public func instant(_ query: Query) -> [Item] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let (prompt, relevance) = Self.prefixed(text).map { ($0, Item.Relevance.exact) } ?? (text, .fallback)
        return [
            Item(
                id: "ask-ai:ask", title: AskAI.title, subtitle: prompt, icon: .symbol(name: AskAI.symbol),
                relevance: relevance, actions: [AskAI.action(asking: prompt)], origin: AskAI.command)
        ]
    }

    /// The question after the `ai` prefix and a space, if there is one.
    static func prefixed(_ text: String) -> String? {
        let words = text.split(separator: " ", maxSplits: 1)
        guard words.count == 2, words[0].lowercased() == AskAI.prefix else { return nil }
        let rest = words[1].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}
