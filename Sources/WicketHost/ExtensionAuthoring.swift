import Foundation
import WicketCore

/// How Wicket extends itself through the user's agent (see docs/architecture.md): what a run is told,
/// and the review offered for the extensions it added or changed, so nothing it wrote runs before the
/// user enables it.
@MainActor
public final class ExtensionAuthoring {
    let extensions: Extensions
    /// The commands Wicket has now (the registry's).
    let commands: @MainActor () -> [RegisteredCommand]
    /// The user's own instructions, added after the rules.
    let instructionsFile: URL
    /// Wicket's rules, as it ships them; nil when this build doesn't bundle them.
    let rules: URL?
    /// The authoring kit (guide, schema, samples); nil when this build doesn't bundle it.
    let kit: URL?
    /// The `wicket` tool, whose `check` the agent can run on its work; nil outside the app.
    let tool: URL?
    /// Where each run's command list is written.
    let commandList: URL
    /// The markup reference that completes the rules' "Your reply"; an evaluation swaps its guidance.
    let reference: String

    public init(
        extensions: Extensions, commands: @escaping @MainActor () -> [RegisteredCommand],
        instructionsFile: URL, commandList: URL,
        rules: URL? = ExtensionAuthoring.bundledRules,
        kit: URL? = ExtensionAuthoring.bundledKit, tool: URL? = ExtensionAuthoring.bundledTool,
        reference: String = Markup.agentReference()
    ) {
        self.extensions = extensions
        self.commands = commands
        self.instructionsFile = instructionsFile
        self.rules = rules
        self.kit = kit
        self.tool = tool
        self.commandList = commandList
        self.reference = reference
    }

    /// `agent.md` in the settings folder (`~/.config/wicket`, or Wicket Dev's), next to settings.json.
    public static var instructionsFile: URL { Settings.directory().appending(path: "agent.md") }

    /// Resources/agent.md as `Scripts/build-app.sh` bundles it (`Contents/Resources/agent.md`).
    public static var bundledRules: URL? {
        Bundle.main.url(forResource: "agent", withExtension: "md")
    }

    /// `Contents/Resources/Authoring`: docs/extensions.md, its schema and samples, laid out as in the
    /// repository so the guide's relative links work.
    public static var bundledKit: URL? {
        Bundle.main.url(forResource: "Authoring", withExtension: nil)
    }

    /// `Contents/Helpers/wicket` in the app bundle, if it is there.
    public static var bundledTool: URL? {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wicket")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// The user's instructions file for Settings ▸ AI to open, created with a one-line comment if it
    /// doesn't exist.
    public static func editableInstructions(file: URL = instructionsFile) throws -> URL {
        guard !FileManager.default.fileExists(atPath: file.path) else { return file }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<!-- Your own instructions for Wicket's agent, added after Wicket's built-in rules. -->\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The most commands the command list holds; the rest are counted.
    static let commandLimit = 300
    /// The longest title, keyword or subtitle listed, so one odd manifest can't inflate the list.
    static let fieldLimit = 80

    /// What a run is told, read again for every run so an edit applies to the next one: the rules,
    /// ending with "Your reply", which the markup reference generated from the catalog completes;
    /// the user's instructions (without HTML comments); then the live part. Writes the run's
    /// command list.
    func instructions() -> String {
        let rules = self.rules.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let own = ((try? String(contentsOf: instructionsFile, encoding: .utf8)) ?? "")
            .replacing(/<!--[\s\S]*?-->/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            rules.trimmingCharacters(in: .whitespacesAndNewlines),
            reference.trimmingCharacters(in: .whitespacesAndNewlines),
            own.isEmpty ? "" : "## The user's own instructions\n\n" + own, live(),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The paths a run needs, absolute, since they differ per Mac and edition.
    private func live() -> String {
        var lines = ["## This Wicket", "", "- Extensions folder: \(extensions.directory.path)"]
        if let kit {
            let docs = kit.appending(path: "docs")
            lines.append("- Authoring guide: \(docs.appending(path: "extensions.md").path)")
            lines.append("- Schema: \(docs.appending(path: "extension.schema.json").path)")
            let samples = [docs.appending(path: "examples"), kit.appending(path: "Extensions")].flatMap(
                Self.folders)
            if !samples.isEmpty {
                lines.append(
                    "- Samples: " + samples.map(\.path).joined(separator: ", "))
            }
        } else {
            lines.append("- Authoring guide: none in this build; follow an existing extension.")
        }
        if let tool {
            lines.append(
                "- `wicket` tool: \(tool.path) (so `wicket check <folder>` is `\(tool.path) check <folder>`)")
            lines.append(
                "- An extension's recent runs in Wicket (outcome, error, input of failed runs, stderr): "
                    + "`\(tool.path) log <id>`")
        }
        if writeCommandList() {
            lines.append("- Command list: \(commandList.path)")
        }
        return lines.joined(separator: "\n")
    }

    /// The subfolders of `folder`, by name.
    private static func folders(in folder: URL) -> [URL] {
        let found = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        return (found ?? []).filter { $0.hasDirectoryPath }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Writes every command Wicket has now to `commandList`, with what an agent needs to name, run or
    /// change it; false if it couldn't.
    private func writeCommandList() -> Bool {
        let all = commands().sorted { $0.id.description < $1.id.description }
        var lines = [
            "# Wicket's commands", "",
            "Every command Wicket has now. Ids are stable: `builtin:<name>` for Wicket's own, "
                + "`ext:<extension>/<command>` for an extension's.", "",
        ]
        lines += all.prefix(Self.commandLimit).map(line)
        if all.count > Self.commandLimit { lines.append("- and \(all.count - Self.commandLimit) more") }
        do {
            try FileManager.default.createDirectory(
                at: commandList.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(
                to: commandList, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// One command: id, title, subtitle, keyword, how it takes input, and its extension's folder.
    private func line(_ command: RegisteredCommand) -> String {
        var line = "- `\(command.id)` \(Self.clipped(command.title))"
        if let subtitle = command.subtitle { line += ": " + Self.clipped(subtitle) }
        line += "."
        if let keyword = command.keyword { line += " Keyword `\(Self.clipped(keyword))`." }
        line += " " + Self.input(command.input)
        if !command.isOffered { line += " Not in search: reached by its id only." }
        if case .extension(let id) = command.id.owner {
            line += " Folder: \(extensions.directory.appending(path: id).path)"
        }
        return line
    }

    private static func input(_ input: CommandInput) -> String {
        switch input {
        case .none: "Takes no text."
        case .immediateText: "Runs at once (mode `once`)."
        case .submitText: "Runs on the text it is given, when submitted."
        case .liveText: "Runs again as the text changes (mode `live`)."
        }
    }

    private static func clipped(_ text: String) -> String {
        text.count > fieldLimit ? text.prefix(fieldLimit - 1) + "…" : text
    }

    /// What each extension folder held when a run started, to compare with after it.
    struct Snapshot {
        var fingerprints: [String: String]
    }

    /// Discovers every folder again first, so a change made just before the run (whose watcher event
    /// hasn't arrived) counts as the starting point, not as the run's work.
    func snapshot() async -> Snapshot {
        await extensions.reload().value
        return Snapshot(
            fingerprints: Dictionary(extensions.discovered.map { ($0.id, Self.fingerprint($0)) }) { a, _ in a
            })
    }

    /// The extensions added or changed since `before` that don't run as they are now (new, changed or
    /// invalid), once every folder has been discovered again; oldest id first.
    func changed(since before: Snapshot) async -> [DiscoveredExtension] {
        await extensions.reload().value
        return extensions.discovered.filter { found in
            if case .approved = found.state { return false }
            return before.fingerprints[found.id] != Self.fingerprint(found)
        }
    }

    /// Fix with Agent: a Run Agent run about the extension `id`, told why it fails, in a frame titled
    /// by the extension (the failure is too long for a title).
    static func fix(_ name: String, id: String, failure: String) -> Item.Action {
        .run(
            command: .runAgent, text: "Find out why it fails and fix it.\n\n\(failure)",
            args: ["title": .string("Fix \(name)"), "extension": .string(id)], title: "Fix with Agent")
    }

    /// Change with Agent: a Run Agent frame waiting for what to change in the extension `id`, typed
    /// or spoken, then a run like Fix with Agent's.
    static func change(id: String) -> Item.Action {
        .run(command: .runAgent, args: ["extension": .string(id)], title: "Change with Agent")
    }

    /// What a run about the extension `id` (Fix or Change with Agent) is told before the request:
    /// which extension, where it is and how to read its runs, so a new conversation knows as much
    /// as the one that built it.
    func about(_ id: String) -> String {
        guard let found = extensions.discovered.first(where: { $0.id == id }) else {
            return "About my Wicket extension `\(id)`:"
        }
        let name = (found.sealed ?? found.approved)?.manifest.name ?? id
        var line = "About my Wicket extension \(name) (`\(id)`, in \(found.folder.path))"
        if let tool { line += "; its recent runs in Wicket: `\(tool.path) log \(id)`" }
        return line + ":"
    }

    /// One review action per extension, each opening its review screen (`builtin:review-extension`).
    static func reviews(_ changed: [DiscoveredExtension]) -> [Item.Action] {
        changed.map { found in
            let name = (found.sealed ?? found.approved)?.manifest.name ?? found.id
            return .run(
                command: .reviewExtension, args: ["id": .string(found.id)], title: "Review and Enable \(name)"
            )
        }
    }

    /// A folder's content as discovery last saw it: its revision, else (it can't be sealed) its
    /// files' latest modification and count, since the same error can survive an edit.
    private static func fingerprint(_ found: DiscoveredExtension) -> String {
        if let sealed = found.sealed { return sealed.revision.sha256 }
        return "unsealed: " + marker(of: found.folder)
    }

    /// The latest modification date and number of the first 500 entries under `folder`.
    private static func marker(of folder: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var latest = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        var count = 0
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in walk {
                count += 1
                if count > 500 { break }
                if let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate,
                    date > latest
                {
                    latest = date
                }
            }
        }
        return "\(latest.timeIntervalSinceReferenceDate)/\(count)"
    }
}
