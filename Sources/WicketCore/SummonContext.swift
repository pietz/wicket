import Foundation

/// What the user had selected in the app they summoned Wicket from: the text selected in its focused
/// field, or the files selected in Finder. Captured after the palette shows (`ContextCapture`, app),
/// held by the session for that summon and stamped into the invocation of each command that uses it
/// (`RegisteredCommand.usesContext`), so a runner reads it from one place, `Invocation.context`.
/// Never logged: it is the user's content.
public struct SummonContext: Sendable, Hashable {
    /// The app's display name, such as "Mail".
    public var app: String
    public var bundleID: String?
    /// The selected text, at most `textLimit` characters; nil if none.
    public var text: String?
    /// The selected files; empty if none.
    public var files: [URL]

    /// Longer selections are cut to this many characters, so a select-all can't swamp a prompt.
    public static let textLimit = 20_000

    /// Nil when nothing was selected: text that is only whitespace counts as none.
    public init?(app: String, bundleID: String? = nil, text: String? = nil, files: [URL] = []) {
        let text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard text != nil || !files.isEmpty else { return nil }
        self.app = app
        self.bundleID = bundleID
        self.text = text.map { String($0.prefix(Self.textLimit)) }
        self.files = files
    }

    /// What the chip in the pill says: "Mail · 42 words", "Finder · 3 items".
    public var summary: String {
        var parts = [app]
        if let text {
            let words = text.split(whereSeparator: \.isWhitespace).count
            parts.append(words == 1 ? "1 word" : "\(words) words")
        }
        if !files.isEmpty {
            parts.append(files.count == 1 ? "1 item" : "\(files.count) items")
        }
        return parts.joined(separator: " · ")
    }

    /// The tagged block a prompt ends with, so "this" in the question has something to refer to.
    public var promptBlock: String {
        var lines = ["<context>", "The user asked this from \(app), with this selected:"]
        if let text {
            lines += ["<selected_text>", text, "</selected_text>"]
        }
        if !files.isEmpty {
            lines += ["<selected_files>"] + files.map(\.path) + ["</selected_files>"]
        }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }
}
