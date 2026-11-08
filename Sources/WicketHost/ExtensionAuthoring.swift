import Foundation
import WicketCore

/// How Wicket extends itself through the user's agent. An acting run is told what Wicket has (its
/// commands, for "what can you do?") and how to add or change a command: an extension in the
/// extensions folder, written per the bundled authoring guide. Once the run has ended, the extensions
/// it added or changed are offered for review: the same review, check and Enable as any other, so
/// nothing it wrote runs before the user enables it.
@MainActor
public final class ExtensionAuthoring {
    let extensions: Extensions
    /// The commands Wicket has now (the registry's).
    let commands: @MainActor () -> [RegisteredCommand]
    /// The extension authoring guide; nil when this build doesn't bundle it.
    let guide: URL?
    /// The `wicket` tool, whose `check` the agent can run on its work; nil outside the app.
    let tool: URL?

    public init(
        extensions: Extensions, commands: @escaping @MainActor () -> [RegisteredCommand],
        guide: URL? = ExtensionAuthoring.bundledGuide, tool: URL? = ExtensionAuthoring.bundledTool
    ) {
        self.extensions = extensions
        self.commands = commands
        self.guide = guide
        self.tool = tool
    }

    /// docs/extensions.md as `Scripts/build-app.sh` bundles it (`Contents/Resources/extensions.md`).
    public static var bundledGuide: URL? {
        Bundle.main.url(forResource: "extensions", withExtension: "md")
    }

    /// `Contents/Helpers/wicket` in the app bundle, if it is there.
    public static var bundledTool: URL? {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wicket")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// The most commands an acting run is told about; the rest are counted.
    static let commandLimit = 60

    /// What an acting run is told after Wicket's own instructions. Short, since it ships with every
    /// run: the guide is a path to read, not pasted in.
    func instructions() -> String {
        let offered = commands().filter(\.isOffered)
        var lines = offered.prefix(Self.commandLimit).map { command in
            var line = "- " + command.title
            if let keyword = command.keyword { line += ", keyword `\(keyword)`" }
            if case .extension(let id) = command.id.owner { line += " (extension `\(id)`)" }
            return line
        }
        if offered.count > Self.commandLimit {
            lines.append("- and \(offered.count - Self.commandLimit) more")
        }
        let guide =
            self.guide.map {
                "Before writing one, read the authoring guide at \($0.path): it is the whole contract (manifest, protocol, the `session.jsonl` fixture its check replays, canned data under `WICKET_CHECK`)."
            } ?? "Follow an existing extension in that folder: this build of Wicket has no authoring guide."
        let check = tool.map { " Wicket's check is `\($0.path) check <folder>`." } ?? ""
        return """
            About Wicket itself: it is a native macOS launcher. Typing finds apps and files and does \
            maths, units and currencies; any text can go to you (the AI) or to a web search. Its commands \
            now:
            \(lines.joined(separator: "\n"))

            Commands come from extensions, one folder per extension named by its id, in \
            \(extensions.directory.path). To add a command or change one (when the user asks for a \
            command, an extension or a feature in Wicket), write or edit an extension folder there. \
            \(guide) Test it as the guide says.\(check) Wicket runs nothing new or changed until the user \
            reviews and enables it in Wicket, which offers that under your reply, so end by saying what \
            you made and that it is ready to review and enable. Don't touch Wicket's own files elsewhere.
            """
    }

    /// What each extension folder held when a run started, to compare with after it.
    struct Snapshot {
        var fingerprints: [String: String]
    }

    func snapshot() -> Snapshot {
        Snapshot(
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

    /// One review action per extension, each opening its review screen (`builtin:review-extension`).
    static func reviews(_ changed: [DiscoveredExtension]) -> [Item.Action] {
        changed.map { found in
            let name = (found.sealed ?? found.approved)?.manifest.name ?? found.id
            return .run(
                command: .reviewExtension, args: ["id": .string(found.id)], title: "Review and Enable \(name)"
            )
        }
    }

    /// A folder's content as discovery last saw it: its revision, or why it has none.
    private static func fingerprint(_ found: DiscoveredExtension) -> String {
        if let sealed = found.sealed { return sealed.revision.sha256 }
        if case .invalid(let reason, _) = found.state { return "invalid: " + reason }
        return ""
    }
}
