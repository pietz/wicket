import Foundation
import WicketCore
import os

extension CommandID {
    /// Run Agent: answers a question or does what it asks, the one AI entry.
    public static let runAgent = CommandID.builtin("run-agent")
    /// Opens Settings on its AI pane: the action of a Run Agent frame whose provider isn't ready.
    /// Hidden, reached by id only; the app's table gives it its effect.
    public static let aiSettings = CommandID.builtin("ai-settings")
    /// Answers an acting agent's approval shown in a Run Agent frame (`token` and `decision` args).
    /// Hidden, reached by id only.
    public static let aiApproval = CommandID.builtin("ai-approval")
    /// Continues the conversation of a Run Agent answer (its `conversation` arg) with the submitted
    /// text: the action under a finished answer, whose frame waits for the question. Hidden, reached
    /// by id only.
    public static let followUp = CommandID.builtin("follow-up")
}

/// Run Agent: acts with the chosen provider, in the folder of the Finder selection or the home
/// folder; its approvals are answered through
/// `builtin:ai-approval`. With the stream's `authoring`, an acting run knows Wicket and can add or
/// change its commands, and its answer offers to review what it wrote. It owns the shared answer
/// stream's shutdown, prompt commands' runs included.
@MainActor
public final class AgentRunner: CommandRunner {
    public let answers: AnswerStream
    /// Supplies the finished answer's Save as Command action in the app. No action during streaming
    /// or after failure; the saver keeps the original invocation out of action arguments.
    public var saveCommand: (@MainActor (Invocation) -> Item.Action?)?

    public init(answers: AnswerStream) {
        self.answers = answers
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        if invocation.command == .aiApproval { return answers.reply(invocation) }
        let question = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt =
            question.isEmpty
            ? "" : (invocation.context.map { question + "\n\n" + $0.promptBlock } ?? question)
        var submitted = invocation
        submitted.text = question
        if invocation.command == .followUp {
            // The conversation's folder and context stay; a follow-up is no prompt to save.
            return answers.run(
                submitted, prompt: question, title: question,
                continuing: invocation.args?["conversation"]?.string ?? "")
        }
        // A run started for the user, such as Fix with Agent, can name its frame; else the question does.
        return answers.run(
            submitted, prompt: prompt, title: invocation.args?["title"]?.string ?? question,
            actingIn: Self.folder(for: invocation.context)
        ) { [weak self] in
            self?.saveCommand?(invocation).map { [$0] } ?? []
        }
    }

    /// Where an acting run works: the folder of the Finder selection (a selected folder itself when it
    /// is the only item), else the home folder.
    static func folder(for context: SummonContext?) -> URL {
        guard let files = context?.files, let first = files.first else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return files.count == 1 && isFolder ? first : first.deletingLastPathComponent()
    }

    public func shutdown() async { await answers.shutdown() }
}
