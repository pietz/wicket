import SwiftUI
import WicketCore

/// Settings ▸ Shortcuts: a global hotkey and an alias for each command the root lists (and Ask AI).
/// Both are preferences in settings.json (`commands`, keyed by the command's canonical id); like
/// every pane this only writes the file, and the reload applies it.
struct ShortcutsPane: View {
    let store: SettingsStore
    @State private var recorder = ShortcutRecorder()
    /// The command the recorder is recording for.
    @State private var recording: CommandID?
    /// What went wrong with the last change, per command.
    @State private var errors: [CommandID: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(commands) { command in
                    row(command)
                }
            } footer: {
                Text(
                    "A hotkey runs its command from anywhere. An alias typed alone in Wicket lists its "
                        + "command first; followed by a space, it works like the command's keyword."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { recorder.stop() }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if !isRecording { recording = nil }
        }
    }

    /// Listed commands and Ask AI; hidden and root-mode commands can still be bound in the file.
    private var commands: [RegisteredCommand] {
        store.commands.filter { $0.isListed || $0.id == AskAI.command }
    }

    private func row(_ command: RegisteredCommand) -> some View {
        let binding = store.settings.commands[command.id]
        let isRecording = recording == command.id && recorder.isRecording
        let note =
            isRecording
            ? (recorder.rejected
                ? "Add ⌘, ⌃ or ⌥ to the key (F-keys work alone). Esc cancels." : "Esc cancels.")
            : errors[command.id] ?? store.bindingProblems[command.id]
        return LabeledContent {
            HStack(spacing: 6) {
                AliasField(alias: binding?.alias) { setAlias($0, for: command) }
                Button {
                    if isRecording { recorder.stop() } else { record(command) }
                } label: {
                    Text(isRecording ? "Press a shortcut…" : binding?.hotkey?.symbols ?? "Record Hotkey")
                        .frame(minWidth: 96)
                }
                Button {
                    update(command.id) { $0.hotkey = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove the hotkey")
                .opacity(binding?.hotkey == nil ? 0 : 1)
                .disabled(binding?.hotkey == nil)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(isRecording ? Color.secondary : Color.red)
                    }
                }
            } icon: {
                Image(nsImage: IconCache.image(for: command.icon))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
        }
    }

    private func record(_ command: RegisteredCommand) {
        errors[command.id] = nil
        recording = command.id
        recorder.start(pausing: store.pauseHotKey) { shortcut in
            switch store.settings.hotkeyConflict(shortcut, for: command.id, isRegistered: isRegistered) {
            case .palette: errors[command.id] = "\(shortcut.symbols) opens Wicket."
            case .taken(let other): errors[command.id] = "\(shortcut.symbols) is already \(title(other))'s."
            case nil: update(command.id) { $0.hotkey = shortcut }
            }
        }
    }

    private func setAlias(_ text: String, for command: RegisteredCommand) {
        let alias = text.trimmingCharacters(in: .whitespaces)
        guard alias != store.settings.commands[command.id]?.alias ?? "" else {
            errors[command.id] = nil
            return
        }
        if alias.isEmpty {
            update(command.id) { $0.alias = nil }
        } else if !CommandBinding.isValidAlias(alias) {
            errors[command.id] = "An alias is one word of at most 32 characters."
        } else if let other = store.settings.aliasConflict(alias, for: command.id, isRegistered: isRegistered)
        {
            errors[command.id] = "The alias is already \(title(other))'s."
        } else {
            update(command.id) { $0.alias = alias }
        }
    }

    /// A binding of a command that isn't registered (an extension not installed, a feature off) is
    /// inert and takes nothing, so it is no conflict here either.
    private func isRegistered(_ id: CommandID) -> Bool {
        store.commands.contains { $0.id == id }
    }

    private func title(_ id: CommandID) -> String {
        store.commands.first { $0.id == id }?.title ?? id.description
    }

    private func update(_ id: CommandID, _ change: (inout CommandBinding) -> Void) {
        do {
            try store.update { settings in
                var binding = settings.commands[id] ?? CommandBinding()
                change(&binding)
                settings.commands[id] = binding.isEmpty ? nil : binding
            }
            errors[id] = nil
        } catch {
            errors[id] = error.localizedDescription
        }
    }
}

/// An alias text field that commits on Return and when it loses focus, and follows the file while
/// it isn't being edited.
private struct AliasField: View {
    let alias: String?
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Alias", text: $text, prompt: Text("Alias"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 84)
            .focused($focused)
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, focused in
                if !focused { commit(text) }
            }
            .onChange(of: alias, initial: true) { _, alias in
                if !focused { text = alias ?? "" }
            }
    }
}
