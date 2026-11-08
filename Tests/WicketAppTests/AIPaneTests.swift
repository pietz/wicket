import Testing
import WicketCore

@testable import WicketApp
@testable import WicketHost

// Settings ▸ AI's provider picker: which provider it shows and when it says how to set one up.

private func statuses(_ states: [AgentProvider: AgentStatus.State]) -> [AgentProvider: AgentStatus] {
    states.reduce(into: [:]) { $0[$1.key] = AgentStatus(provider: $1.key, state: $1.value) }
}

@MainActor @Test func thePickerShowsTheChosenProviderElseTheFirstReadyOne() {
    let codexOnly = statuses([.claude: .loggedOut, .codex: .ready])
    #expect(AIPane.current(chosen: nil, statuses: codexOnly) == .codex)
    #expect(AIPane.current(chosen: nil, statuses: statuses([.claude: .ready, .codex: .ready])) == .claude)
    // A chosen provider stays shown even when it stops being ready: Run Agent never swaps it.
    #expect(AIPane.current(chosen: .claude, statuses: codexOnly) == .claude)
    // While asking, or with none ready: Claude.
    #expect(AIPane.current(chosen: nil, statuses: [:]) == .claude)
}

@MainActor @Test func noneReadyOnlyOnceEveryProviderAnswered() {
    #expect(!AIPane.noneReady([:]))
    #expect(!AIPane.noneReady(statuses([.claude: .notInstalled])))
    #expect(AIPane.noneReady(statuses([.claude: .notInstalled, .codex: .loggedOut])))
    #expect(!AIPane.noneReady(statuses([.claude: .notInstalled, .codex: .ready])))
}
