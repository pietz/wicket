import ApplicationServices
import SwiftUI
import WicketCore
import WicketHost

/// Settings ▸ AI: which provider answers Ask AI (and acts, when it can), and whether each one is
/// ready. The choice is a preference in settings.json (`ai.provider`); the status is checked when the
/// pane opens.
struct AIPane: View {
    let store: SettingsStore
    @State private var statuses: [AgentProvider: AgentStatus] = [:]
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
                    "Codex and Claude answer on your own subscription. Codex also does what you ask, "
                        + "building Wicket commands included, under the permissions you set in Codex. "
                        + "Automatic uses the first provider that's ready, Codex first. Claude only "
                        + "answers for now, with no tools and no access to your files."
                )
                .foregroundStyle(.secondary)
                Text("Apple Intelligence is a small, free, offline on-device model for quick answers only.")
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
                    "Ask AI also sees what you had selected when you opened Wicket, shown at the end of "
                        + "the bar. Press Delete in the empty field to leave it out. Selected text needs "
                        + "Accessibility; Finder's selection needs permission to control Finder."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await check() }
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
