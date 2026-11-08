import Foundation
import WicketCore

/// The answer so far, as the frame shows it.
@MainActor
final class AnswerDraft {
    let title: String
    let invocation: Invocation
    /// Continues the conversation, once the answer has come from a run whose session the
    /// agent kept: second among the actions, so ⌘↩ runs it.
    var followUp: Item.Action?
    /// Reviews of the extensions the run added or changed, first among the finished answer's actions.
    var reviews: [Item.Action] = []
    /// Shown until the first text arrives.
    let status: String
    /// Everything the agent wrote, in order: its messages along the way, then its final answer.
    /// Tools it used and its thinking aren't shown.
    var text = ""
    /// The final answer alone, once it has come: what Copy and Paste take.
    var answer: String?
    /// Offered after Retry when the run continued a remembered conversation and failed.
    var startFresh: Item.Action?
    /// The agent's questions waiting for the user, oldest first, each with its action token.
    var approvals: [(token: String, approval: AgentApproval)] = []
    /// Approvals the user answered, kept out until the agent confirms them resolved.
    private var answered: Set<JSONValue> = []
    /// Why the run failed, once it has.
    var failure: String?
    /// Shows the latest state; set by the run.
    var redraw: () -> Void = {}

    init(title: String, invocation: Invocation, status: String) {
        self.title = title
        self.invocation = invocation
        self.status = status
    }

    /// A whole message the agent wrote, set apart from the last by a blank line.
    func add(_ message: String) {
        text += text.isEmpty ? message : "\n\n" + message
    }

    /// The agent's waiting approvals, keeping the tokens of those already shown.
    func show(_ waiting: [AgentApproval]) {
        answered.formIntersection(waiting.map(\.id))
        approvals = waiting.filter { !answered.contains($0.id) }.map { approval in
            (approvals.first { $0.approval == approval }?.token ?? UUID().uuidString, approval)
        }
    }

    func answer(_ token: String, _ approval: AgentApproval) {
        answered.insert(approval.id)
        approvals.removeAll { $0.token == token }
        redraw()
    }

    /// The question is the title (the pill shows it), the answer the page, after what the agent did
    /// and, first, the question it is waiting on, whose answers are then the actions. Nothing to act
    /// on until text arrives; a failed run keeps what it sent, marked incomplete, with Retry first.
    /// The page is the agent's (its markup's rows act under `.agent`); every action on it is Wicket's,
    /// so they are the screen's, with ⌘↩ on the second (Follow Up, Deny).
    var result: RunResult {
        func screen(_ detail: Detail, _ actions: [Item.Action] = []) -> RunResult {
            .show(.detail(detail), ScreenContext(authority: .agent, actions: actions, secondary: 1))
        }
        let final = plain(answer ?? text)
        let copy = Item.Action.copy(text: final, title: "Copy Answer")
        guard let failure else {
            let body = text.isEmpty ? "_\(status)_" : text
            if let (token, approval) = approvals.first {
                return screen(
                    Detail(title: title, markdown: [ask(approval), body].joined(separator: "\n\n")),
                    [decide(token, .accept, "Allow"), decide(token, .decline, "Deny")])
            }
            if text.isEmpty { return screen(Detail(title: title, markdown: body)) }
            var actions = reviews + [copy, .paste(text: final, title: "Paste Answer")]
            if let followUp { actions.insert(followUp, at: 1) }
            return screen(Detail(title: title, markdown: body), actions)
        }
        let retry = Item.Action.run(
            command: invocation.command, text: invocation.text,
            args: invocation.args, title: "Retry", revision: invocation.revision)
        let retries = [retry] + (startFresh.map { [$0] } ?? [])
        guard !text.isEmpty else {
            return screen(
                Detail.failure("Run Agent Failed", failure, command: invocation.command), reviews + retries)
        }
        return screen(
            Detail(title: title, markdown: text + "\n\n---\n\n**The answer is incomplete.** " + failure),
            reviews + retries + [copy])
    }

    /// The last text made plain, for Copy and Paste: the reply's markup as a document's text, tags
    /// dropped. Kept, so a redraw that didn't change the text doesn't parse it again.
    private var plainText: (source: String, text: String)?

    private func plain(_ markup: String) -> String {
        if let plainText, plainText.source == markup { return plainText.text }
        let text = Markup.plainText(markup, home: FileManager.default.homeDirectoryForCurrentUser)
        plainText = (markup, text)
        return text
    }

    private func ask(_ approval: AgentApproval) -> String {
        var parts =
            switch approval.kind {
            case .command:
                [
                    approval.workingDirectory.map {
                        "**The agent asks to run a command** in " + Self.escaped(Self.abbreviated($0)) + "."
                    } ?? "**The agent asks to run a command.**"
                ]
            case .network: ["**The agent asks to reach** " + Self.escaped(approval.subject) + "."]
            case .fileChange: ["**The agent asks to change files:** " + Self.escaped(approval.subject)]
            case .tool: ["**The agent asks to use** " + Self.escaped(approval.subject) + "."]
            }
        if let root = approval.grantRoot {
            parts.append(
                "It asks to write anywhere in " + Self.escaped(Self.abbreviated(root))
                    + " for the rest of this run.")
        }
        if let reason = approval.reason, !reason.isEmpty { parts.append(Self.escaped(reason)) }
        if approval.kind == .command { parts.append(Self.fenced(approval.subject)) }
        if let input = approval.input { parts.append(Self.fenced(input)) }
        if approvals.count > 1 { parts.append("_\(approvals.count - 1) more waiting_") }
        return parts.joined(separator: "\n\n")
    }

    private func decide(_ token: String, _ decision: AgentDecision, _ title: String) -> Item.Action {
        .run(
            command: .aiApproval, args: ["token": .string(token), "decision": .string(decision.rawValue)],
            title: title)
    }

    /// An absolute path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Text shown as is: Markdown's punctuation escaped.
    static func escaped(_ text: String) -> String {
        text.map { "\\`*_{}[]<>()#+-.!|~&".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    /// A code block that no backtick run inside `code` can close.
    static func fenced(_ code: String) -> String {
        let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + code + "\n" + fence
    }
}
