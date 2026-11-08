import ApplicationServices
import SwiftUI
import WicketCore
import WicketHost

/// Settings ▸ AI: which provider Run Agent uses and how it runs. One picker chooses Claude or
/// ChatGPT, only those that are installed and signed in; below it, the chosen one's model, effort,
/// speed and permission level. Provider, model, effort and speed are preferences in settings.json
/// (`ai`); the permission level is consent, so it goes to `AgentPermissions`, which only this pane
/// writes. Each provider's status and models are asked when the pane opens.
struct AIPane: View {
    let store: SettingsStore
    let permissions: AgentPermissions
    @State private var statuses: [AgentProvider: AgentStatus] = [:]
    /// Each CLI's models as it lists them; missing while asking or if it couldn't.
    @State private var models: [AgentProvider: [AgentModel]] = [:]
    /// The permission levels as the store holds them, so the picker redraws when one changes.
    @State private var levels: [AgentProvider: AgentPermission] = [:]
    @State private var checking = false
    @State private var error: String?
    @State private var textAccess = AXIsProcessTrusted()
    @State private var finderAccess: ContextCapture.FinderAccess?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let problem = permissions.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            providerSection(current)
            optionsSection(current)
            Section {
                Button("Edit Agent Instructions…") { editInstructions() }
            } footer: {
                Text(
                    "What Run Agent tells your agent about Wicket, in agent.md next to settings.json. "
                        + "Delete the file to go back to Wicket's default."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Selected text") {
                    if textAccess {
                        allowed
                    } else {
                        Button("Allow…") {
                            // `kAXTrustedCheckOptionPrompt`'s value: the constant is a global var.
                            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                            textAccess = AXIsProcessTrustedWithOptions(options)
                        }
                    }
                }
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
                Text("Selection")
            } footer: {
                Text(
                    "Run Agent also sees what you had selected when you opened Wicket, shown at the end of "
                        + "the bar. Press Delete in the empty field to leave it out. Selected text needs "
                        + "Accessibility; Finder's selection needs permission to control Finder."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            for provider in AgentProvider.allCases { levels[provider] = permissions.level(for: provider) }
            async let listing: Void = listModels()
            await check()
            await listing
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

    /// The chosen provider's model, effort, speed and permission level.
    private func optionsSection(_ provider: AgentProvider) -> some View {
        let options = store.settings.ai[provider]
        let listed = models[provider]
        let model = listed?.first { $0.id == options.model }
        // A model or effort the file names that the CLI doesn't list still shows, as written.
        var modelIDs = listed?.map(\.id) ?? []
        if !modelIDs.contains(options.model) { modelIDs.append(options.model) }
        var efforts = model?.efforts ?? Self.union(listed?.map(\.efforts) ?? [])
        if !efforts.contains(options.effort) { efforts.append(options.effort) }
        let level = levels[provider] ?? permissions.level(for: provider)
        var notes = ["Fast answers sooner but uses more of your plan.", "\(level.title): \(level.summary)."]
        if provider == .claude, level == .auto {
            notes.append(
                "Where Claude's auto mode isn't available to your account, it asks as in Supervised.")
        }
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
            Picker("Permissions", selection: self.level(provider)) {
                ForEach(AgentPermission.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
        } footer: {
            Text(notes.joined(separator: " ")).foregroundStyle(.secondary)
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

    /// A field of one agent's options in settings.json. Choosing a model moves an effort it doesn't
    /// have to medium (or its first) and drops a fast speed it doesn't have.
    private func binding<Value>(_ provider: AgentProvider, _ field: WritableKeyPath<AgentOptions, Value>)
        -> Binding<Value>
    {
        Binding {
            store.settings.ai[provider][keyPath: field]
        } set: { value in
            let listed = models[provider] ?? []
            do {
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
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The permission level, written to the host store, never to settings.json.
    private func level(_ provider: AgentProvider) -> Binding<AgentPermission> {
        Binding {
            levels[provider] ?? permissions.level(for: provider)
        } set: { level in
            do {
                try permissions.set(level, for: provider)
                levels[provider] = permissions.level(for: provider)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Opens agent.md in the user's editor (or reveals it if nothing opens Markdown), writing the
    /// default there first if it doesn't exist.
    private func editInstructions() {
        do {
            let file = try ExtensionAuthoring.editableInstructions()
            if !NSWorkspace.shared.open(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            error = nil
        } catch {
            self.error = error.localizedDescription
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
            do {
                try store.update { $0.ai.provider = provider }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
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
        textAccess = AXIsProcessTrusted()
        await checkFinder(ask: false)
        await withTaskGroup(of: AgentStatus.self) { group in
            for provider in AgentProvider.allCases {
                group.addTask { await Agent.status(of: provider) }
            }
            for await status in group { statuses[status.provider] = status }
        }
    }
}
