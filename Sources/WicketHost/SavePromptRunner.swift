import Foundation
import WicketCore

extension CommandID {
    public static let savePromptCommand = CommandID.builtin("save-prompt-command")
}

/// Save as Command: turns a finished Run Agent question into a prompt command and opens its review.
/// The hidden action holds only a token: the original question and selection stay in memory until
/// explicitly saved. Running prompt commands is `Extensions`'.
@MainActor
public final class SavePromptRunner: CommandRunner {
    private let extensions: Extensions
    private let reviews: ExtensionsRunner
    private var offers: [(token: String, invocation: Invocation)] = []
    private var saving: [UUID: Task<Void, Never>] = [:]
    private var isShutDown = false

    public init(extensions: Extensions, reviews: ExtensionsRunner) {
        self.extensions = extensions
        self.reviews = reviews
    }

    public func offer(_ invocation: Invocation) -> Item.Action {
        let token = UUID().uuidString
        offers.append((token, invocation))
        offers = Array(offers.suffix(32))
        return .run(command: .savePromptCommand, args: ["save": .string(token)], title: "Save as Command")
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        guard !isShutDown else {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let id = UUID()
        let task = Task {
            do {
                try Task.checkCancellation()
                guard case .string(let token)? = invocation.args?["save"],
                    let offered = offers.first(where: { $0.token == token })
                else {
                    throw Refusal("Save a finished agent answer from its action menu.")
                }
                let folder = try Self.write(offered.invocation, into: extensions.directory)
                offers.removeAll { $0.token == token }
                await extensions.load(changed: [folder.path]).value
                try Task.checkCancellation()
                let review = Invocation(
                    command: .reviewExtension, args: ["id": .string(folder.lastPathComponent)])
                for try await result in reviews.run(review, retry: .never) { continuation.yield(result) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            saving[id] = nil
        }
        saving[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Writes only a manifest, never the answer or captured selection. A hidden draft is renamed
    /// into place when complete; a unique id keeps existing commands untouched.
    static func write(_ invocation: Invocation, into directory: URL) throws -> URL {
        let question = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw Refusal("There's no question to save.") }
        var template = question
        if let selection = invocation.context?.text {
            if template.contains(selection) {
                template = template.replacingOccurrences(of: selection, with: "{selection}")
            } else {
                template += "\n\n{selection}"
            }
        }
        if invocation.context?.files.isEmpty == false { template += "\n\n{files}" }
        if let problem = PromptTemplate.problem(template) {
            throw Refusal("Couldn't save the prompt: " + problem)
        }
        // The title and keyword must not retain a selection that appeared inside the question.
        let title = String(template.components(separatedBy: "\n").first!.prefix(64))
        let words = title.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }.map(
            String.init
        )
        .filter { !["selection", "text", "app", "files"].contains($0) }
        let keyword = String((words.last ?? "prompt").prefix(32))
        let stem = String(words.joined(separator: "-").prefix(40)).trimmingCharacters(
            in: CharacterSet(charactersIn: "-"))
        let id =
            "prompt-" + (stem.isEmpty ? "command" : stem) + "-" + UUID().uuidString.prefix(8).lowercased()
        let manifest: [String: Any] = [
            "protocol": 1, "id": id, "name": title, "version": "1.0.0",
            "description": "A saved agent prompt. Edit wicket.json to change its name, keyword or prompt.",
            "commands": [
                [
                    "id": "ask", "title": title, "keyword": keyword, "prompt": template,
                    "search": [String(title.prefix(128))],
                ]
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = directory.appending(path: ".prompt-\(UUID().uuidString)")
        try files.createDirectory(at: draft, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: draft) }
        try data.write(to: draft.appending(path: Manifest.fileName), options: .atomic)
        _ = try Manifest.load(from: draft)
        let folder = directory.appending(path: id)
        try files.moveItem(at: draft, to: folder)
        return folder
    }

    public func shutdown() async {
        isShutDown = true
        let tasks = Array(saving.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        offers = []
    }
}
