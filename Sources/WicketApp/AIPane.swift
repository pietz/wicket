import ApplicationServices
import SwiftUI
import WicketCore
import WicketHost

/// Settings ▸ AI: which provider answers Run Agent (and acts, when it can), whether each one is
/// ready, and how each agent CLI runs. Provider, model, effort and speed are preferences in
/// settings.json (`ai`); the permission level is consent, so it goes to `AgentPermissions`, which
/// only this pane writes. The status and each CLI's models are asked when the pane opens.
struct AIPane: View {
    let store: SettingsStore
    let permissions: AgentPermissions
    @State private var statuses: [AgentProvider: AgentStatus] = [:]
    /// Each CLI's models as it lists them; missing while asking or if it couldn't.
    @State private var models: [AgentProvider: [AgentModel]] = [:]
    /// The permission levels as the store holds them, so the pickers redraw when one changes.
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
            Section {
                Picker("AI provider", selection: provider) {
                    Text("Automatic").tag(AgentProvider?.none)
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        Text(provider.name).tag(AgentProvider?.some(provider))
                    }
                }
            } footer: {
                Text(
                    "Codex and Claude Code run on your own subscription and do what you ask, building "
                        + "Wicket commands included. Automatic uses the first provider that's ready, Codex first."
                )
                .foregroundStyle(.secondary)
                Text("Apple Intelligence is a small, free, offline on-device model for quick answers only.")
                    .foregroundStyle(.secondary)
            }
            if let problem = permissions.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ForEach(AgentProvider.allCases.filter(\.acts), id: \.self) { provider in
                agentSection(provider)
            }
            Section {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    LabeledContent(provider.name) {
                        StatusLabel(status: statuses[provider])
                    }
                }
            } header: {
                HStack {
                    Text("Status")
                    Spacer()
                    Button("Check Again") { Task { await check() } }
                        .disabled(checking)
                }
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

    /// One agent CLI's model, effort, speed and permission level. "Default" leaves each to the
    /// agent's own configuration.
    private func agentSection(_ provider: AgentProvider) -> some View {
        let options = store.settings.ai[provider]
        let listed = models[provider]
        let model = listed?.first { $0.id == options.model }
        // An effort or model the file names that the CLI doesn't list still shows, as written.
        var modelIDs = listed?.map(\.id) ?? []
        if let chosen = options.model, !modelIDs.contains(chosen) { modelIDs.append(chosen) }
        var efforts = model?.efforts ?? Self.union(listed?.map(\.efforts) ?? [])
        if let chosen = options.effort, !efforts.contains(chosen) { efforts.append(chosen) }
        return Section {
            Picker("Model", selection: binding(provider, \.model)) {
                Text("Default").tag(String?.none)
                ForEach(modelIDs, id: \.self) { id in
                    Text(listed?.first { $0.id == id }?.name ?? id).tag(String?.some(id))
                }
            }
            Picker("Reasoning effort", selection: binding(provider, \.effort)) {
                Text("Default").tag(String?.none)
                ForEach(efforts, id: \.self) { effort in
                    Text(Self.effortName(effort)).tag(String?.some(effort))
                }
            }
            Picker("Speed", selection: binding(provider, \.speed)) {
                Text("Regular").tag(AgentSpeed.regular)
                Text("Fast").tag(AgentSpeed.fast)
            }
            .disabled(model?.fast == false && options.speed == .regular)
            Picker("Permissions", selection: level(provider)) {
                Text("\(provider.name)'s own settings").tag(AgentPermission?.none)
                ForEach(AgentPermission.allCases, id: \.self) { level in
                    Text(level.title).tag(AgentPermission?.some(level))
                }
            }
        } header: {
            Text(provider.name)
        } footer: {
            Text(
                [
                    "Default uses what you set in \(provider.name). Fast answers sooner but uses more of "
                        + "your plan.",
                    levels[provider].map { "\($0.title): \($0.summary)." }
                        ?? "Permissions: \(provider.name) asks or acts as its own settings say.",
                ].joined(separator: " ")
            )
            .foregroundStyle(.secondary)
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

    /// A field of one agent's options in settings.json. Choosing a model drops an effort or the fast
    /// speed it doesn't have.
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
                    if field == \AgentOptions.model, let chosen = options.model,
                        let model = listed.first(where: { $0.id == chosen })
                    {
                        if let effort = options.effort, !model.efforts.contains(effort) {
                            options.effort = nil
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
    private func level(_ provider: AgentProvider) -> Binding<AgentPermission?> {
        Binding {
            levels[provider]
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

    private var allowed: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Off the main actor: asking blocks until the user answers macOS's prompt.
    private func checkFinder(ask: Bool) async {
        finderAccess = await Task.detached { ContextCapture.finderAccess(ask: ask) }.value
    }

    private var provider: Binding<AgentProvider?> {
        Binding {
            store.settings.ai.provider
        } set: { provider in
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
            for provider in AgentProvider.allCases where provider.acts {
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

private struct StatusLabel: View {
    let status: AgentStatus?

    var body: some View {
        if let status {
            VStack(alignment: .trailing, spacing: 2) {
                switch status.state {
                case .ready:
                    Label(
                        ["Ready", status.version].compactMap { $0 }.joined(separator: " · "),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case .loggedOut:
                    Label("Signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("Run `\(status.provider.loginCommand ?? "")` in Terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Label("Unavailable", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notInstalled:
                    Label("Not installed", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let warning = status.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
