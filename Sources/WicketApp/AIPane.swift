import SwiftUI
import WicketCore
import WicketHost

/// Settings ▸ AI: which agent CLI answers Ask AI and builds Make a Command, and whether each one is
/// ready. The choice is a preference in settings.json (`ai.provider`); the status is checked when the
/// pane opens.
struct AIPane: View {
    let store: SettingsStore
    @State private var statuses: [AgentProvider: AgentStatus] = [:]
    @State private var checking = false
    @State private var error: String?

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
                    "It answers questions (Ask AI) and builds commands (Make a Command), on your own "
                        + "subscription. Automatic uses the first one that's ready, Codex first. Answers "
                        + "get no tools and no access to your files; a build writes only into the new "
                        + "command's own folder."
                )
                .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await check() }
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

    private func check() async {
        checking = true
        defer { checking = false }
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
                    Text("Run `\(status.provider.loginCommand)` in Terminal")
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
