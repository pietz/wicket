import Foundation
import Testing
import WicketCore

@testable import WicketHost

// How well real agents follow the reply rules: varied prompts through Run Agent with Wicket's real
// rules, each reply parsed as the palette parses it and linted as `wicket run` lints an extension's.
// Opt in with `WICKET_EVAL_MARKUP=claude` (or `codex`, or both, comma-separated); it runs on the
// user's subscription with their agent configuration, allows every approval the agent asks for (the
// prompts only read), and writes one JSON line per reply to `WICKET_EVAL_OUT` (a file) if set.
// Results: docs/reviews/2026-11-08-markup-eval.md.

/// A prompt, and whether a good reply to it is plain Markdown (no tags but `<answer>`).
private let prompts: [(id: String, plain: Bool, text: String)] = [
    ("capital", true, "What's the capital of Australia?"),
    ("leap", true, "How many days are in a leap year?"),
    ("rebase", true, "What does git rebase do? Two sentences."),
    ("translate", true, "How do you say \"good morning\" in Japanese?"),
    ("swift-rust", false, "Compare Swift and Rust for writing a command-line tool."),
    ("phones", false, "Compare the iPhone 16 Pro and the Pixel 9 Pro: price, battery, camera."),
    ("eu-population", false, "What are the populations of the five largest EU countries?"),
    (
        "revenue", false,
        "Our monthly revenue: Jan 12k, Feb 15k, Mar 9k, Apr 18k, May 21k, Jun 24k. How is it trending?"
    ),
    ("weather", false, "What's the weather in Berlin right now?"),
    ("disk", false, "How much disk space is free on this Mac?"),
    ("ssh", false, "How do I set up an SSH key for GitHub? Step by step."),
    ("downloads", false, "What are the 8 newest files in my Downloads folder?"),
    ("python-json", false, "How do I read a JSON file in Python? Short example."),
    ("apollo", false, "Give me a timeline of the crewed Apollo missions."),
]

private struct Outcome: Codable {
    var provider: String
    var id: String
    var plain: Bool
    var seconds: Double
    var bytes: Int
    var blocks: Int
    /// Top-level components, by tag name, excluding `<answer>`.
    var components: [String]
    var answer: Bool
    var issues: [String]
    var failed: String?
    var markdown: String
}

@MainActor @Test func replyMarkupEvaluation() async throws {
    let wanted = (ProcessInfo.processInfo.environment["WICKET_EVAL_MARKUP"] ?? "").split(separator: ",")
    let providers = AgentProvider.allCases.filter { wanted.contains(Substring($0.rawValue)) }
    guard !providers.isEmpty else { return }
    let out = ProcessInfo.processInfo.environment["WICKET_EVAL_OUT"].map { URL(filePath: $0) }

    let root = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/eval-\(UUID().uuidString)")
    let directory = root.appending(path: "Extensions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
        .standardizedFileURL
    let authoring = ExtensionAuthoring(
        extensions: extensions, commands: { [] }, instructionsFile: root.appending(path: "agent.md"),
        commandList: root.appending(path: "commands.md"),
        rules: repository.appending(path: "Resources/agent.md"), kit: repository, tool: nil)

    // The providers side by side, each a few prompts at a time: every prompt is a CLI process.
    let runs = providers.map { provider in
        Task {
            let runner = AgentRunner(answers: AnswerStream(provider: { provider }))
            runner.answers.authoring = authoring
            var outcomes: [Outcome] = []
            for batch in stride(from: 0, to: prompts.count, by: 4) {
                let tasks = prompts[batch..<min(batch + 4, prompts.count)].map { prompt in
                    Task { await ask(runner, provider: provider, prompt) }
                }
                for task in tasks { outcomes.append(await task.value) }
            }
            return outcomes
        }
    }
    var outcomes: [Outcome] = []
    for run in runs { outcomes += await run.value }
    if let out {
        let encoder = JSONEncoder()
        let lines = try outcomes.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    }
    for provider in providers {
        let mine = outcomes.filter { $0.provider == provider.rawValue && $0.failed == nil }
        let clean = mine.count(where: { $0.issues.isEmpty })
        let over = mine.count(where: { $0.plain && !$0.components.isEmpty })
        let largest = mine.max { $0.bytes < $1.bytes }
        print(
            "EVAL \(provider.rawValue): \(clean)/\(mine.count) clean, \(over) plain prompts with tags, "
                + "\(outcomes.count(where: { $0.provider == provider.rawValue && $0.failed != nil })) failed, largest \(largest?.bytes ?? 0) B / \(largest?.blocks ?? 0) blocks"
        )
    }
}

/// Asks `prompt` and evaluates the page the palette would draw, allowing whatever the agent asks.
@MainActor
private func ask(
    _ runner: AgentRunner, provider: AgentProvider, _ prompt: (id: String, plain: Bool, text: String)
) async -> Outcome {
    let start = ContinuousClock.now
    var last: Detail?
    var failed: String?
    do {
        for try await result in runner.run(Invocation(command: .runAgent, text: prompt.text)) {
            guard case .show(.detail(let detail), let context) = result else { continue }
            last = detail
            if case .run(.aiApproval, let text, let args, _, _)? = context.actions.first {
                for try await _ in runner.run(Invocation(command: .aiApproval, text: text, args: args)) {}
            }
        }
    } catch {
        failed = "\(error)"
    }
    let markdown = last?.markdown ?? ""
    if markdown.contains("**The answer is incomplete.**") || last?.title == "Run Agent Failed" {
        failed = failed ?? "incomplete"
    }
    var parser = Markup.Parser()
    let parsed = parser.parse(markdown)
    let components: [String] = parsed.document.blocks.compactMap { block in
        guard case .component(let node) = block else { return nil }
        let name = "\(type(of: node))"
        return name == "Answer" ? nil : name
    }
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    return Outcome(
        provider: provider.rawValue, id: prompt.id, plain: prompt.plain, seconds: seconds,
        bytes: markdown.utf8.count, blocks: parsed.document.blocks.count, components: components,
        answer: parsed.document.blocks.contains { $0.component(Answer.self) != nil },
        issues: Markup.lint(markdown).map(\.description), failed: failed, markdown: markdown)
}
