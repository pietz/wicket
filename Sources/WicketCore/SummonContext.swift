import Foundation

/// The files the user had selected in Finder when they summoned Wicket: Run Agent works in their
/// folder and is told which they are. Captured after the palette shows (`ContextCapture`, app), held
/// by the session for that summon and stamped into the invocation of each command that uses it
/// (`RegisteredCommand.usesContext`), so a runner reads it from one place, `Invocation.context`.
/// Never logged: it is the user's content.
public struct SummonContext: Sendable, Hashable {
    /// The selected files, never empty.
    public var files: [URL]

    /// Nil when nothing was selected.
    public init?(files: [URL]) {
        guard !files.isEmpty else { return nil }
        self.files = files
    }

    /// What the chip in the pill says: "Finder · 3 items".
    public var summary: String {
        "Finder · " + (files.count == 1 ? "1 item" : "\(files.count) items")
    }

    /// The tagged block a prompt ends with, so "these" in the question has something to refer to.
    public var promptBlock: String {
        (["<context>", "The user asked this from Finder, with these selected:", "<selected_files>"]
            + files.map(\.path) + ["</selected_files>", "</context>"]).joined(separator: "\n")
    }
}
