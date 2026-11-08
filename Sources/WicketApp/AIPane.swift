import SwiftUI
import WicketCore
import WicketHost

/// Settings ▸ AI: whether Wicket uses AI at all (`ai.enabled`; off, the rest of the pane is hidden),
/// then which provider Run Agent uses (Claude or ChatGPT, only those installed and signed in) and its
/// model, effort and speed, all in settings.json (`ai`). What the agent may do unasked is its own
/// configuration, which the footer points to. Status and models are asked when the pane opens.
struct AIPane: View {
    let store: SettingsStore
    @State private var statuses: [AgentProvider: AgentStatus] = [:]
    /// Each CLI's models as it lists them; missing while asking or if it couldn't.
    @State private var models: [AgentProvider: [AgentModel]] = [:]
    @State private var checking = false
    @State private var error: String?
    @State private var finderAccess: ContextCapture.FinderAccess?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                Toggle("Use AI", isOn: store.binding(\.ai.enabled, error: $error))
            } footer: {
                Text(
                    store.settings.ai.enabled
                        ? "Run Agent hands what you ask to the agent chosen below."
                        : "Nothing in Wicket uses AI, and Run Agent leaves the search."
                )
                .foregroundStyle(.secondary)
            }
            if store.settings.ai.enabled { details }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            async let listing: Void = listModels()
            await check()
            await listing
        }
    }

    /// Everything below the switch, while AI is on.
    @ViewBuilder private var details: some View {
        providerSection(current)
        optionsSection(current)
        Section {
            Button("Edit Agent Instructions…") { editInstructions() }
        } footer: {
            Text(
                "Your own instructions for the agent, in agent.md next to settings.json. Run Agent "
                    + "adds them after Wicket's built-in rules."
            )
            .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Files selected in Finder") {
                switch finderAccess {
                case .granted: allowed
                case .notAsked: Button("Allow…") { Task { await checkFinder(ask: true) } }
                case .refused:
                    Button("Open Automation Settings") {
                        NSWorkspace.shared.open(Self.automationSettings)
                    }
                case nil: ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Finder")
        } footer: {
            Text(
                "Opened from Finder, Run Agent works in the folder of the files you had selected and "
                    + "knows which they are, shown at the end of the bar. Press Delete in the empty "
                    + "field to leave them out. This needs permission to control Finder."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var current: AgentProvider {
        Self.current(chosen: store.settings.ai.provider, statuses: statuses)
    }

    /// The provider Run Agent uses: the chosen one, else the first ready one, as `AgentBackend.ready`
    /// picks it (Claude while the statuses are being asked or if none is ready).
    static func current(chosen: AgentProvider?, statuses: [AgentProvider: AgentStatus]) -> AgentProvider {
        chosen ?? AgentProvider.allCases.first { statuses[$0]?.state == .ready } ?? .claude
    }

    /// Whether every provider was asked and none is ready, so the pane says how to set one up.
    static func noneReady(_ statuses: [AgentProvider: AgentStatus]) -> Bool {
        statuses.count == AgentProvider.allCases.count && !statuses.values.contains { $0.state == .ready }
    }

    /// The provider picker: one that isn't ready is greyed out, says why and can't be chosen. No
    /// checkmark on ready ones: the menu already checks the selected one.
    private func providerSection(_ current: AgentProvider) -> some View {
        Section {
            Picker("AI provider", selection: provider(current)) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    switch statuses[provider]?.state {
                    case .ready: Text(provider.name).tag(provider)
                    case .loggedOut: Text("\(provider.name) (not signed in)").tag(provider).disabled(true)
                    case .notInstalled: Text("\(provider.name) (not installed)").tag(provider).disabled(true)
                    case nil: Text(provider.name).tag(provider)
                    }
                }
            }
        } footer: {
            if Self.noneReady(statuses) {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        "To use Run Agent, install Claude Code or Codex and sign in with `claude auth login` "
                            + "or `codex login` in Terminal."
                    )
                    Spacer()
                    Button("Check Again") { Task { await check() } }.disabled(checking)
                }
                .foregroundStyle(.secondary)
            } else if let warning = statuses[current]?.warning {
                Text("\(current.cli): \(warning).").foregroundStyle(.secondary)
            }
        }
    }

    /// The chosen provider's model, effort and speed; the footer says where its permissions are set.
    private func optionsSection(_ provider: AgentProvider) -> some View {
        let options = store.settings.ai[provider]
        let listed = models[provider]
        let model = listed?.first { $0.id == options.model }
        // A model or effort the file names that the CLI doesn't list still shows, as written.
        var modelIDs = listed?.map(\.id) ?? []
        if !modelIDs.contains(options.model) { modelIDs.append(options.model) }
        var efforts = model?.efforts ?? Self.union(listed?.map(\.efforts) ?? [])
        if !efforts.contains(options.effort) { efforts.append(options.effort) }
        return Section {
            Picker("Model", selection: binding(provider, \.model)) {
                ForEach(modelIDs, id: \.self) { id in
                    Text(listed?.first { $0.id == id }?.name ?? id).tag(id)
                }
            }
            Picker("Reasoning effort", selection: binding(provider, \.effort)) {
                ForEach(efforts, id: \.self) { effort in
                    Text(Self.effortName(effort)).tag(effort)
                }
            }
            Picker("Speed", selection: binding(provider, \.speed)) {
                Text("Regular").tag(AgentSpeed.regular)
                Text("Fast").tag(AgentSpeed.fast)
            }
            .disabled(model?.fast == false && options.speed == .regular)
        } footer: {
            Text(
                LocalizedStringKey(
                    Self.speedNote(provider, model: model) + " " + Self.permissions(provider))
            )
            .foregroundStyle(.secondary)
        }
    }

    /// Where the agent's own permission policy is set, which Run Agent follows.
    static func permissions(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude:
            "Claude asks before acting as its permission mode says: set `permissions.defaultMode` in "
                + "~/.claude/settings.json (auto, acceptEdits or default), and Wicket shows its questions."
        case .codex:
            "ChatGPT asks before acting as Codex's `approval_policy` and `sandbox_mode` in "
                + "~/.codex/config.toml say, and Wicket shows its questions."
        }
    }

    /// Every effort any model lists, in the order they first appear.
    static func union(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// What Fast costs and where it is offered: Claude Code has it only on Opus, billed from usage
    /// credits; Codex's priority tier uses more of the plan.
    static func speedNote(_ provider: AgentProvider, model: AgentModel?) -> String {
        switch provider {
        case .claude where model?.fast == false: "Fast is only offered on Opus."
        case .claude: "Fast answers sooner and is billed from Claude usage credits, not your plan."
        case .codex: "Fast answers sooner but uses more of your plan."
        }
    }

    /// A field of one agent's options in settings.json. Choosing a model moves an effort it doesn't
    /// have to medium (or its first) and drops a fast speed it doesn't have.
    private func binding<Value>(_ provider: AgentProvider, _ field: WritableKeyPath<AgentOptions, Value>)
        -> Binding<Value>
    {
        Binding {
            store.settings.ai[provider][keyPath: field]
        } set: { value in
            let listed = models[provider] ?? []
            perform(error: $error) {
                try store.update { settings in
                    var options = settings.ai[provider]
                    options[keyPath: field] = value
                    if field == \AgentOptions.model,
                        let model = listed.first(where: { $0.id == options.model })
                    {
                        if let first = model.efforts.first, !model.efforts.contains(options.effort) {
                            options.effort = model.efforts.contains("medium") ? "medium" : first
                        }
                        if !model.fast { options.speed = .regular }
                    }
                    settings.ai[provider] = options
                }
            }
        }
    }

    /// Opens agent.md in the user's editor (or reveals it if nothing opens Markdown), creating it
    /// first if it doesn't exist.
    private func editInstructions() {
        perform(error: $error) {
            let file = try ExtensionAuthoring.editableInstructions()
            if !NSWorkspace.shared.open(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

    private var allowed: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Off the main actor: asking blocks until the user answers macOS's prompt.
    private func checkFinder(ask: Bool) async {
        finderAccess = await Task.detached { ContextCapture.finderAccess(ask: ask) }.value
    }

    /// Choosing writes the provider, so it stays when the other one becomes ready too; one that isn't
    /// ready is never written.
    private func provider(_ current: AgentProvider) -> Binding<AgentProvider> {
        Binding {
            current
        } set: { provider in
            guard statuses[provider]?.state == .ready else { return }
            perform(error: $error) { try store.update { $0.ai.provider = provider } }
        }
    }

    /// Each CLI's models, asked once per opening of the pane.
    private func listModels() async {
        await withTaskGroup(of: (AgentProvider, [AgentModel]?).self) { group in
            for provider in AgentProvider.allCases {
                group.addTask { (provider, await Agent.locate(provider)?.models()) }
            }
            for await (provider, list) in group { models[provider] = list }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        await checkFinder(ask: false)
        await withTaskGroup(of: AgentStatus.self) { group in
            for provider in AgentProvider.allCases {
                group.addTask { await Agent.status(of: provider) }
            }
            for await status in group { statuses[status.provider] = status }
        }
    }
}
