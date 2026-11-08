import AVFoundation
import SwiftUI

/// Settings ▸ Voice: whether and when Wicket listens, and what that needs (the microphone, a
/// language, the on-device model). Turning voice on is consent (`VoiceConsent`), so this pane writes
/// it, never settings.json, and it is where the microphone is asked for: never at a summon, where a
/// dialog would take the keyboard from the palette.
struct VoicePane: View {
    let consent: VoiceConsent
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var locale: Locale?
    @State private var model = ModelState.checking
    @State private var working = false
    @State private var error: String?

    enum ModelState: Equatable {
        case checking, ready, missing, unavailable
        case downloading(Double)
    }

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                Toggle("Voice input", isOn: enabled)
                    .disabled(working)
                if consent.mode != .off {
                    Picker("Start listening", selection: trigger) {
                        Text("When Wicket opens").tag(VoiceMode.onOpen)
                        Text("Only when I ask").tag(VoiceMode.onCommand)
                    }
                }
            } footer: {
                Text(footer).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Microphone") { microphoneStatus }
                LabeledContent("Language") {
                    Text(
                        locale.map {
                            Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
                        }
                            ?? (model == .unavailable ? "None of yours is supported" : "…")
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Speech model") { modelStatus }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await check() }
    }

    /// How to start listening comes first: a hotkey-only trigger proved hard to find.
    private var footer: String {
        let onOpen =
            consent.mode == .onOpen
            ? "When Wicket opens, the microphone turns on quietly: just start talking, or type and it "
                + "turns off. " : ""
        return "To start listening, click the microphone in the search field or press ⌘L. " + onOpen
            + "Your words appear in the search field as you say them, transcribed on this Mac; Return "
            + "runs the top row, nothing runs by itself. Typing or Esc stops listening. To open Wicket "
            + "listening, give Start Listening a hotkey in Shortcuts."
    }

    @ViewBuilder private var microphoneStatus: some View {
        switch microphone {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.microphoneSettings) }
        default:
            Text("Asked when you turn voice on").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch model {
        case .checking: ProgressView().controlSize(.small)
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Text("Downloaded when you turn voice on").foregroundStyle(.secondary)
        case .unavailable: Text("Unavailable").foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        }
    }

    static let microphoneSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    private var enabled: Binding<Bool> {
        Binding {
            consent.mode != .off
        } set: { on in
            Task { await (on ? turnOn() : turnOff()) }
        }
    }

    private var trigger: Binding<VoiceMode> {
        Binding {
            consent.mode
        } set: { mode in
            save(mode)
        }
    }

    /// Asks for the microphone if it was never asked, downloads the model if it is missing, and only
    /// then records the consent, listening when Wicket opens (the point of voice) until changed.
    private func turnOn() async {
        working = true
        defer { working = false }
        error = nil
        if microphone == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
            microphone = AVAudioApplication.shared.recordPermission
        }
        guard microphone == .granted else {
            error = "Wicket needs the microphone to listen. Allow it in Privacy Settings."
            return
        }
        guard let locale = await resolveLocale() else { return }
        do {
            if try await VoiceLanguage.needsDownload(locale) {
                model = .downloading(0)
                try await VoiceLanguage.install(locale) { model = .downloading($0) }
            }
            model = .ready
        } catch {
            model = .missing
            self.error = "Couldn't download the speech model: \(error.localizedDescription)"
            return
        }
        await VoiceLanguage.reserve(locale, true)
        save(.onOpen)
    }

    private func turnOff() async {
        save(.off)
        if let locale { await VoiceLanguage.reserve(locale, false) }
    }

    private func save(_ mode: VoiceMode) {
        do {
            try consent.set(mode)
        } catch {
            self.error = "Couldn't save the voice setting: \(error.localizedDescription)"
        }
    }

    private func check() async {
        microphone = AVAudioApplication.shared.recordPermission
        guard let locale = await resolveLocale() else { return }
        model = (try? await VoiceLanguage.needsDownload(locale)) == false ? .ready : .missing
    }

    private func resolveLocale() async -> Locale? {
        locale = await VoiceLanguage.locale()
        if locale == nil { model = .unavailable }
        return locale
    }
}
