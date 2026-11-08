import Foundation
import Testing
import WicketCore

@testable import WicketHost

// How well real agents follow the reply rules: varied prompts through Run Agent with Wicket's real
// rules, each reply parsed as the palette parses it and linted as `wicket run` lints an extension's.
// Opt in with `WICKET_EVAL_MARKUP=claude` (or `codex`, or both, comma-separated); it runs on the
// user's subscription with their agent configuration, allows every approval the agent asks for (the
// prompts only read), and writes one JSON line per reply to `WICKET_EVAL_OUT` (a file) if set.
// Results: docs/reviews/2026-11-08-markup-eval.md. It reports, per CLI, the replies with no strict
// problem (target all), the structured prompts answered with a fitting component (target 80%) and
// the plain prompts answered with tags (target at most 1 in 10).

/// A prompt and the components that fit a good reply to it, by type name; none means plain Markdown
/// (no tags but `<answer>`). `repo` runs in a fresh git repository with commits from today.
private let prompts: [(id: String, fits: [String], text: String)] = [
    ("capital", [], "What's the capital of Australia?"),
    ("leap", [], "How many days are in a leap year?"),
    ("rebase", [], "What does git rebase do? Two sentences."),
    ("translate", [], "How do you say \"good morning\" in Japanese?"),
    ("tls", [], "Explain briefly how HTTPS keeps a connection private."),
    ("thanks", [], "Thanks, that worked perfectly!"),
    ("ssh", [], "How do I set up an SSH key for GitHub? Step by step."),
    ("python-json", [], "How do I read a JSON file in Python? Short example."),
    ("phones", ["Columns", "Card"], "Compare the iPhone 17 and the Pixel 11."),
    (
        "eu-population", ["Chart", "Stats", "Facts"],
        "What are the populations of the five largest EU countries?"
    ),
    (
        "funnel", ["Stats", "Chart"],
        "Summarize these numbers: this week 12,400 visits, 1,860 signups, 410 paid; last week 11,900 visits, "
            + "1,540 signups, 380 paid."
    ),
    (
        "revenue", ["Chart", "Stats"],
        "Our monthly revenue: Jan 12k, Feb 15k, Mar 9k, Apr 18k, May 21k, Jun 24k. How is it trending?"
    ),
    ("calendar", ["Timeline", "Callout", "Rows"], "What's on my calendar today?"),
    ("repo", ["Timeline", "Rows", "Stats"], "What changed in this repo today?"),
    ("disk", ["Progress", "Stats", "Facts"], "What's the status of my disk usage?"),
    (
        "weather", ["Stats", "Facts", "Columns", "Timeline", "Chart"],
        "What's the weather in Hamburg tomorrow?"
    ),
    ("downloads", ["Rows"], "What are the 8 newest files in my Downloads folder?"),
    ("apollo", ["Timeline"], "Give me a timeline of the crewed Apollo missions."),
]

private struct Outcome: Codable {
    var provider: String
    var id: String
    var plain: Bool
    /// The reply holds a component that fits the prompt.
    var fitting: Bool
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
    let repo = try makeRepository(at: root.appending(path: "repo"))
    let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
        .standardizedFileURL
    let authoring = ExtensionAuthoring(
        extensions: extensions, commands: { [] }, instructionsFile: root.appending(path: "agent.md"),
        commandList: root.appending(path: "commands.md"),
        rules: repository.appending(path: "Resources/agent.md"), kit: repository, tool: nil)

    // The providers side by side, each a few prompts at a time: every prompt is a CLI process.
    let runs = providers.map { provider in
        Task {
            let runner = AgentRunner(provider: { provider })
            runner.authoring = authoring
            var outcomes: [Outcome] = []
            for batch in stride(from: 0, to: prompts.count, by: 4) {
                let tasks = prompts[batch..<min(batch + 4, prompts.count)].map { prompt in
                    Task {
                        await ask(runner, provider: provider, prompt, in: prompt.id == "repo" ? repo : nil)
                    }
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
        let plain = mine.filter(\.plain)
        let over = plain.count(where: { !$0.components.isEmpty })
        let fitting = mine.count(where: { !$0.plain && $0.fitting })
        let largest = mine.max { $0.bytes < $1.bytes }
        print(
            "EVAL \(provider.rawValue): \(clean)/\(mine.count) clean, \(fitting)/\(mine.count - plain.count) "
                + "structured with a fitting component, \(over)/\(plain.count) plain with tags, "
                + "\(outcomes.count(where: { $0.provider == provider.rawValue && $0.failed != nil })) failed, largest \(largest?.bytes ?? 0) B / \(largest?.blocks ?? 0) blocks"
        )
    }
}

/// Asks `prompt` and evaluates the page the palette would draw, allowing whatever the agent asks.
@MainActor
private func ask(
    _ runner: AgentRunner, provider: AgentProvider, _ prompt: (id: String, fits: [String], text: String),
    in folder: URL?
) async -> Outcome {
    let start = ContinuousClock.now
    var last: Detail?
    var failed: String?
    do {
        for try await result in runner.run(
            Invocation(
                command: .runAgent, text: prompt.text, context: folder.flatMap { SummonContext(files: [$0]) })
        ) {
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
        provider: provider.rawValue, id: prompt.id, plain: prompt.fits.isEmpty,
        fitting: components.contains { prompt.fits.contains($0) }, seconds: seconds,
        bytes: markdown.utf8.count, blocks: parsed.document.blocks.count, components: components,
        answer: parsed.document.blocks.contains { $0.component(Answer.self) != nil },
        issues: Markup.lint(markdown).map(\.description), failed: failed, markdown: markdown)
}

/// A git repository with a few commits from today, for "what changed in this repo today".
private func makeRepository(at folder: URL) throws -> URL {
    let files: [(path: String, text: String, message: String)] = [
        ("README.md", "# Tally\n\nCounts words in text files.\n", "Start Tally"),
        ("tally.py", "import sys\nprint(len(open(sys.argv[1]).read().split()))\n", "Count words in a file"),
        (
            "tally.py", "import sys\nfor p in sys.argv[1:]:\n    print(p, len(open(p).read().split()))\n",
            "Count several files"
        ),
        ("tests/test_tally.py", "def test_count():\n    assert True\n", "Add a first test"),
        (
            "README.md", "# Tally\n\nCounts words in text files: `python tally.py a.txt b.txt`.\n",
            "Document usage"
        ),
    ]
    try FileManager.default.createDirectory(
        at: folder.appending(path: "tests"), withIntermediateDirectories: true)
    try git(["init", "-q"], in: folder)
    for file in files {
        try file.text.write(to: folder.appending(path: file.path), atomically: true, encoding: .utf8)
        try git(["add", file.path], in: folder)
        try git(
            ["-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-q", "-m", file.message],
            in: folder)
    }
    return folder
}

private func git(_ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}
