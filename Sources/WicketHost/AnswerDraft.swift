import Foundation
import WicketCore

/// The answer so far, as the frame shows it.
@MainActor
final class AnswerDraft {
    let title: String
    let invocation: Invocation
    /// Continues the conversation, once the answer has come from an acting run whose session the
    /// agent kept: second among the actions, so ⌘↩ runs it.
    var followUp: Item.Action?
    /// Reviews of the extensions the run added or changed, first among the finished answer's actions.
    var reviews: [Item.Action] = []
    /// Shown until the first text arrives.
    let status: String
    /// The permission level the run was started with, said under each question.
    let permission: AgentPermission
    /// Everything the agent wrote, in order: its messages along the way, then its final answer.
    /// Tools it used and its thinking aren't shown.
    var text = ""
    /// Whether text shows as it comes; if not, each message shows once it is whole.
    let streams: Bool
    /// The message being written, while it is kept out of the page (not streaming).
    private var unfinished = ""
    /// The final answer alone, once it has come: what Copy and Paste take.
    var answer: String?
    /// Whether the agent ran a command or changed a file, so a failed resume can't simply start anew.
    var acted = false
    /// The agent's questions waiting for the user, oldest first, each with its action token.
    var approvals: [(token: String, approval: AgentApproval)] = []
    /// Approvals the user answered, kept out until the agent confirms them resolved.
    private var answered: Set<JSONValue> = []
    /// Why the run failed, once it has.
    var failure: String?
    /// Shows the latest state; set by the run.
    var redraw: () -> Void = {}

    init(
        title: String, invocation: Invocation, status: String, permission: AgentPermission, streams: Bool
    ) {
        self.title = title
        self.invocation = invocation
        self.status = status
        self.permission = permission
        self.streams = streams
    }

    /// Adds what the agent wrote and returns whether the page changed: streaming, at once; else it
    /// waits for the message to end.
    func write(_ delta: String) -> Bool {
        if streams { text += delta } else { unfinished += delta }
        return streams
    }

    /// The message being written is whole (or the run ended): it joins the page.
    func endMessage() {
        text += unfinished
        unfinished = ""
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
    var detail: Detail {
        let final = answer ?? text
        let copy = Item.Action.copy(text: final, title: "Copy Answer")
        guard let failure else {
            let body = text.isEmpty ? "_\(status)_" : text
            if let (token, approval) = approvals.first {
                return Detail(
                    title: title, markdown: [ask(approval), body].joined(separator: "\n\n"),
                    actions: [
                        decide(token, .accept, "Allow"),
                        decide(token, .acceptForSession, "Allow for Session"),
                        decide(token, .decline, "Deny"),
                    ])
            }
            if text.isEmpty { return Detail(title: title, markdown: body) }
            var actions = reviews + [copy, .paste(text: final, title: "Paste Answer")]
            if let followUp { actions.insert(followUp, at: 1) }
            return Detail(title: title, markdown: body, actions: actions)
        }
        let retry = Item.Action.run(
            command: invocation.command, text: invocation.text,
            args: invocation.args, title: "Retry", revision: invocation.revision)
        guard !text.isEmpty else {
            var detail = Detail.failure("Run Agent Failed", failure, command: invocation.command)
            detail.actions = reviews + [retry]
            return detail
        }
        return Detail(
            title: title,
            markdown: text + "\n\n---\n\n**The answer is incomplete.** " + failure,
            actions: reviews + [retry, copy])
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
        parts.append("_\(permission.title): \(permission.summary)._")
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
