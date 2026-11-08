import ServiceManagement
import SwiftUI
import WicketCore

/// Settings ▸ General: the hotkey, the palette's width, text size and online content, launch at
/// login, the menu bar icon, updates, the settings file and the extensions folder.
struct GeneralPane: View {
    let store: SettingsStore
    /// Sparkle, for the released app; nil in Wicket Dev, which hides the Updates section.
    let updater: Updater?
    @State private var recorder = ShortcutRecorder()
    /// Launch at login lives in the system (SMAppService), not in settings.json.
    @State private var loginStatus = SMAppService.mainApp.status
    /// Sparkle keeps this in its own defaults; read once when the pane opens.
    @State private var checksAutomatically: Bool?
    @State private var error: String?
    /// The width last written, until settings.json is reloaded with it, so the slider doesn't jump
    /// back while the file catches up.
    @State private var width: Double?

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
                } else if let problem = store.diagnostics.text(for: .hotkey, kind: .hotkey) {
                    Label(
                        "\(problem) Choose another shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            Section {
                Slider(
                    value: paletteWidth, in: Settings.paletteWidths, step: 60,
                    label: { Text("Palette width") },
                    minimumValueLabel: { Text("Narrow") },
                    maximumValueLabel: { Text("Wide") })
                Picker("Text size", selection: store.binding(\.textSize, error: $error)) {
                    ForEach(TextSize.allCases, id: \.self) { size in
                        Text(size.rawValue.capitalized)
                    }
                }
                Toggle(isOn: store.binding(\.showOnlineContent, error: $error)) {
                    Text("Show online content")
                    Text(
                        "Images on a page load from the web. When it's off, Load Images in ⌘K loads a page's."
                    )
                }
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle(isOn: store.binding(\.showInMenuBar, error: $error)) {
                    Text("Show in menu bar")
                    Text("When it's hidden, open Wicket with its shortcut or by opening the app again.")
                }
            }
            if let updater {
                Section {
                    Toggle("Check for updates automatically", isOn: automaticChecks(updater))
                    LabeledContent("Version \(Self.version)") {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                    }
                }
            }
            Section {
                LabeledContent("Files") {
                    HStack {
                        Button("Open settings.json") { perform(error: $error) { try store.openFile() } }
                        Button("Open Extensions Folder") {
                            perform(error: $error) { try store.openExtensionsFolder() }
                        }
                    }
                }
                if let loadError = store.loadError {
                    Label(
                        "\(loadError). Keeping the last good settings until it's fixed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
                ForEach(store.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } footer: {
                Text(
                    "The hotkey, width, text size and menu bar icon are stored in settings.json, which you "
                        + "or an agent can also edit. Launch at login and updates are kept by macOS and the updater."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { recorder.stop() }
        .onChange(of: store.settings.paletteWidth) { _, applied in
            if applied == width { width = nil }
        }
        // The user may have approved or removed the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func record() {
        error = nil
        recorder.start(pausing: store.pauseHotKey) { shortcut in
            perform(error: $error) { try store.update { $0.hotkey = shortcut } }
        }
    }

    private var paletteWidth: Binding<Double> {
        Binding {
            width ?? store.settings.paletteWidth
        } set: { newWidth in
            guard newWidth != (width ?? store.settings.paletteWidth) else { return }
            width = newWidth
            // A failed write never reaches the file, so the slider goes back to what is applied.
            if !perform(error: $error, { try store.update { $0.paletteWidth = newWidth } }) { width = nil }
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func automaticChecks(_ updater: Updater) -> Binding<Bool> {
        Binding {
            checksAutomatically ?? updater.automaticallyChecks
        } set: { enabled in
            updater.automaticallyChecks = enabled
            checksAutomatically = enabled
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { enabled in
            perform(error: $error) {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
            loginStatus = SMAppService.mainApp.status
        }
    }
}
