import ServiceManagement
import SwiftUI
import WicketCore

/// Settings ▸ General: the hotkey, launch at login and the settings file.
struct GeneralPane: View {
    let store: SettingsStore
    @State private var recorder = ShortcutRecorder()
    /// Launch at login lives in the system (SMAppService), not in settings.json.
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                LabeledContent("Open Wicket") {
                    Button {
                        if recorder.isRecording { recorder.stop() } else { record() }
                    } label: {
                        Text(recorder.isRecording ? "Press a shortcut…" : store.settings.hotkey.symbols)
                            .frame(minWidth: 110)
                    }
                }
                if recorder.isRecording {
                    Text(
                        recorder.rejected
                            ? "Add ⌘, ⌃ or ⌥ to the key (F-keys work alone). Esc cancels."
                            : "Esc cancels."
                    )
                    .foregroundStyle(.secondary)
                } else if store.hotKeyFailed {
                    Label(
                        "\(store.settings.hotkey.symbols) is in use by another app. Choose another shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Section {
                LabeledContent("Settings file") {
                    Button("Open settings.json") { perform { try store.openFile() } }
                }
                if let loadError = store.loadError {
                    Label(
                        "\(loadError). Using defaults until it's fixed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            } footer: {
                Text("Every setting here is stored in settings.json, which you or an agent can also edit.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { recorder.stop() }
        // The user may have approved or removed the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func record() {
        error = nil
        recorder.start(pausing: store.pauseHotKey) { shortcut in
            perform { try store.update { $0.hotkey = shortcut } }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { enabled in
            perform {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
