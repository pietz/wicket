import Foundation
import WicketCore
import os

/// What Wicket needs from its AI providers: whether a provider is ready, and an answer run.
/// `installed` uses the CLIs on the login-shell PATH; tests pass stand-ins. Run
/// Agent, prompt commands and `wicket agent ask` all pick their provider through `ready(_:)`.
public struct AgentBackend: Sendable {
    public var status: @Sendable (AgentProvider) async -> AgentStatus
    public var run: @Sendable (AgentProvider, AgentRequest) async -> AgentRun

    public init(
        status: @escaping @Sendable (AgentProvider) async -> AgentStatus,
        run: @escaping @Sendable (AgentProvider, AgentRequest) async -> AgentRun
    ) {
        self.status = status
        self.run = run
    }

    public static let installed = AgentBackend(
        status: { await Agent.status(of: $0) },
        run: { provider, request in
            if let agent = await Agent.locate(provider) { return agent.run(request) }
            let status = AgentStatus(provider: provider, state: .notInstalled)
            return AgentRun {
                $0.yield(.error(status.description))
                return .notRunning
            }
        })

    /// The status of the provider to ask: `chosen` if it is ready, else, with none chosen, the first
    /// ready one of Claude and ChatGPT. Checked on every call, never cached; a chosen
    /// provider that isn't ready is never swapped for another.
    public func ready(_ chosen: AgentProvider?) async throws(AgentUnavailable) -> AgentStatus {
        var statuses: [AgentStatus] = []
        for candidate in chosen.map({ [$0] }) ?? AgentProvider.allCases {
            let start = ContinuousClock.now
            let checked = await status(candidate)
            Self.logger.notice(
                "agent: \(candidate.rawValue, privacy: .public) status in \(ContinuousClock.now - start, privacy: .public)"
            )
            if checked.state == .ready { return checked }
            statuses.append(checked)
        }
        throw AgentUnavailable(statuses: statuses, chosen: chosen != nil)
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "ai")
}

/// No provider can answer: the statuses of those tried, and whether the user chose one.
public struct AgentUnavailable: Error, CustomStringConvertible {
    public let statuses: [AgentStatus]
    public let chosen: Bool

    /// What a frame says, with what to do.
    public var description: String {
        let reasons = statuses.map(Self.reason)
        if chosen, let reason = reasons.first {
            return reason + "\n\nYou can choose another provider in Settings ▸ AI."
        }
        let names = statuses.map { $0.provider.name }.joined(separator: " or ")
        return "Run Agent uses \(names), and none is ready:\n\n"
            + reasons.map { "- \($0)" }.joined(separator: "\n")
    }

    static func reason(_ status: AgentStatus) -> String {
        let provider = status.provider
        return switch status.state {
        case .notInstalled: "\(provider.cli) isn't installed: there's no `\(provider.command)` on your PATH."
        case .loggedOut:
            "\(provider.cli) isn't signed in: run `\(provider.loginCommand)` in Terminal to sign in."
        case .ready: "\(provider.cli) is ready."
        }
    }
}
