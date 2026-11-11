import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private let store: ConfigurationStore
  private let extensions: ExtensionHost
  private let updater: Updater?
  private let pauseHotkey: (Bool) -> Void
  init(
    store: ConfigurationStore, extensions: ExtensionHost, updater: Updater?,
    pauseHotkey: @escaping (Bool) -> Void
  ) {
    self.store = store
    self.extensions = extensions
    self.updater = updater
    self.pauseHotkey = pauseHotkey
  }
  func show(section: Int? = nil) {
    NSApp.setActivationPolicy(.regular)
    if window == nil {
      let tabs = NSTabViewController()
      tabs.tabStyle = .toolbar
      for (index, item) in [
        ("General", "gearshape"), ("Voice", "waveform"),
        ("Agent", "sparkles"), ("Sources", "list.bullet"),
      ].enumerated() {
        let pane = SettingsPane(
          section: index, store: store, extensions: extensions,
          updater: updater, pauseHotkey: pauseHotkey)
        let controller = NSHostingController(rootView: pane)
        controller.title = item.0
        let tab = NSTabViewItem(viewController: controller)
        tab.label = item.0
        tab.image = NSImage(systemSymbolName: item.1, accessibilityDescription: item.0)
        tabs.addTabViewItem(tab)
      }
      let window = NSWindow(contentViewController: tabs)
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.toolbarStyle = .preference
      window.setContentSize(NSSize(width: 560, height: 480))
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      self.window = window
    }
    if let section {
      (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = section
    }
    // Accessory apps cannot reliably activate cooperatively; carried from the first Wicket.
    (NSApp as any SettingsActivation).activate(ignoringOtherApps: true)
    window!.makeKeyAndOrderFront(nil)
  }
  func windowWillClose(_ notification: Notification) {
    window = nil
    NSApp.setActivationPolicy(.accessory)
  }
}

struct SettingsPane: View {
  let section: Int
  let store: ConfigurationStore
  let extensions: ExtensionHost
  let updater: Updater?
  let pauseHotkey: (Bool) -> Void
  @State private var automaticChecks: Bool?
  @State private var recorder = ShortcutRecorder()
  @State private var transparency = TransparencyEdit()
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginProblem: String?
  @State private var inputDevices: [MicrophoneDevice] = []
  @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  private var config: Configuration { store.configuration }

  var body: some View {
    Form {
      if let problem = store.problem {
        Section {
          Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          Text("Keeping the last good configuration. Fix config.json to continue editing.")
          Button("Open Config Folder") { reveal(store.url.deletingLastPathComponent()) }
        }
      }
      if let problem = store.writeProblem {
        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      Group {
        switch section {
        case 0: general
        case 1: voice
        case 2: agent
        default: sourcesSection
        }
      }
      .disabled(store.problem != nil)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 480)
    .onAppear {
      if section == 1 { inputDevices = MicrophoneDevices.available() }
      if section == 2 { store.discoverOptions() }
    }
    .onChange(of: config.agent.agent) { if section == 2 { store.discoverOptions() } }
    .onDisappear { recorder.stop() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      loginStatus = SMAppService.mainApp.status
      microphone = AVCaptureDevice.authorizationStatus(for: .audio)
      if section == 1 { inputDevices = MicrophoneDevices.available() }
    }
  }

  @ViewBuilder private var general: some View {
    Section {
      LabeledContent("Open Wicket") {
        Button(recorder.isRecording ? "Press a shortcut…" : config.hotkey.symbols) {
          if recorder.isRecording {
            recorder.stop()
          } else {
            recorder.start(pausing: pauseHotkey) { shortcut in
              store.setHotkey(shortcut)
            }
          }
        }.frame(minWidth: 120)
      }
      if recorder.isRecording {
        Text(
          recorder.rejected
            ? "Add ⌘, ⌃ or ⌥ (F-keys work alone). Esc cancels." : "Press a shortcut. Esc cancels."
        )
        .foregroundStyle(.secondary)
      }
      if let problem = store.hotkeyProblem {
        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
      Slider(
        value: Binding(
          get: { transparency.value ?? config.backgroundTransparency }, set: { transparency.value = $0 }),
        in: 0...1
      ) {
        Text("Background transparency")
      } minimumValueLabel: {
        Text("Solid")
      } maximumValueLabel: {
        Text("Clear")
      } onEditingChanged: { editing in
        transparency.editingChanged(editing, store: store)
      }
      Picker("Text size", selection: binding(config.textSize.rawValue, key: "textSize")) {
        ForEach(Configuration.TextSize.allCases, id: \.self) { size in
          Text(size.rawValue.capitalized).tag(size.rawValue)
        }
      }
    }
    Section {
      Toggle(
        "Launch at login",
        isOn: Binding(
          get: {
            loginStatus == .enabled || loginStatus == .requiresApproval
          },
          set: { enabled in
            do {
              if enabled {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
              loginProblem = nil
            } catch {
              loginProblem =
                "macOS couldn't change launch at login. An ad hoc signed build may be refused. \(error.localizedDescription)"
            }
            loginStatus = SMAppService.mainApp.status
          }))
      if loginStatus == .requiresApproval {
        Text("Waiting for approval in Login Items.").foregroundStyle(.secondary)
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
      } else if loginStatus == .notFound {
        Text("macOS couldn't find a registered login item for this build.").foregroundStyle(.secondary)
      }
      if let loginProblem { Text(loginProblem).foregroundStyle(.red) }
    } footer: {
      Text("Launch at login is managed by macOS.")
    }
    if let updater {
      Section {
        Toggle(
          "Check for updates automatically",
          isOn: Binding(
            get: { automaticChecks ?? updater.automaticallyChecks },
            set: {
              updater.automaticallyChecks = $0
              automaticChecks = $0
            }))
        LabeledContent("Version \(Self.version)") {
          Button("Check for Updates…") { updater.checkForUpdates() }
        }
      }
    }
    Section {
      Button("Open Config Folder") { reveal(store.url.deletingLastPathComponent()) }
    } footer: {
      Text("Settings live in config.json. You and your agent can still edit it directly.")
    }
  }

  @ViewBuilder private var voice: some View {
    Section {
      Toggle("Voice input", isOn: binding(config.voice.enabled, key: "enabled", group: "voice"))
    } footer: {
      Text("Wicket listens when the launcher opens. Start typing to take over.")
    }
    Section {
      Picker(
        "Microphone", selection: binding(config.voice.microphone ?? "", key: "microphone", group: "voice")
      ) {
        Text("Automatic").tag("")
        ForEach(inputDevices, id: \.uid) { device in Text(device.name).tag(device.uid) }
        if let uid = config.voice.microphone, !uid.isEmpty, !inputDevices.contains(where: { $0.uid == uid }) {
          Text("Unavailable (using Automatic)").tag(uid)
        }
      }
      Text("Automatic avoids Bluetooth headset microphones, which switch the headset into call mode.")
        .font(.callout).foregroundStyle(.secondary)
      LabeledContent("Permission", value: microphoneText)
      Button("Open Microphone Settings") {
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
      }
    } header: {
      Text("Microphone")
    } footer: {
      Text(
        "Speech is transcribed on your Mac. Opening Settings never starts listening or requests permission.")
    }
  }
  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
  private var microphoneText: String {
    switch microphone {
    case .authorized: "Allowed"
    case .denied: "Denied"
    case .restricted: "Restricted by macOS"
    case .notDetermined: "Not requested yet"
    @unknown default: "Unknown"
    }
  }

  @ViewBuilder private var agent: some View {
    Section {
      Picker(
        "Agent",
        selection: Binding(
          get: { config.agent.agent.rawValue },
          set: { name in
            store.change { file in
              try file.selectAgent(name)
            }
          })
      ) {
        Text("Claude").tag("claude")
        Text("ChatGPT").tag("codex")
      }
      option("Model", key: "model", help: "Choose the model for new answers.")
      option("Reasoning effort", key: "effort", help: "More effort spends longer thinking before answering.")
      option("Permission mode", key: "mode", help: "Auto lets the agent decide what needs your approval.")
      if AgentOptions.offersFast(config.agent, models: store.models) {
        option("Speed", key: "speed", help: "Fast answers quicker and uses more of your allowance.")
      }
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "Stream answers", isOn: binding(config.agent.streamAnswers, key: "streamAnswers", group: "agent"))
        Text("Show answers as they arrive. Turn off for completed steps.").font(.callout).foregroundStyle(
          .secondary)
      }
    } footer: {
      Text(
        store.discoveryStatus[config.agent.agent.rawValue]
          ?? (store.models.isEmpty
            ? "Loading settings…"
            : "Changes apply on the next turn. Switching agent starts a new conversation."))
    }
    Section(config.agent.agent.product) {
      if AgentCLI.installed(config.agent.agent) {
        Label("\(config.agent.agent.product) is installed", systemImage: "checkmark.circle")
        Text("Sign-in is checked when you ask the agent.").foregroundStyle(.secondary)
      } else {
        Text(
          "\(config.agent.agent.product) isn't installed. Install it, then run \(config.agent.agent.signIn) in Terminal."
        )
        .textSelection(.enabled).font(.callout)
      }
    }
  }
  private func option(_ title: String, key: String, help: String) -> some View {
    let items = AgentOptions.choices(store.models, key: key, for: config.agent)
    let value = AgentOptions.resolved(config.agent, key: key, models: store.models)
    let saved =
      [
        "model": config.agent.model, "effort": config.agent.effort, "mode": config.agent.mode,
        "speed": config.agent.speed,
      ][key] ?? nil
    return VStack(alignment: .leading, spacing: 4) {
      Picker(
        title,
        selection: Binding(
          get: { saved ?? "" },
          set: { value in
            store.change { try $0.set(key, to: value.isEmpty ? nil : value, in: "agent") }
          })
      ) {
        Text("Default").tag("")
        ForEach(items, id: \.value) { item in
          Text(item.title + (item.available ? "" : " (unavailable)")).tag(item.value).disabled(
            !item.available)
        }
        if saved != nil && !items.contains(where: { $0.value == value }) {
          Text("Saved: " + value).tag(value)
        }
      }
      Text(help).font(.callout).foregroundStyle(.secondary)
    }
  }

  private var sources: [Configuration.ProviderEntry] { config.sources(extensions: extensions.ids) }
  @ViewBuilder private var sourcesSection: some View {
    Section {
      ForEach(sources, id: \.id) { source in
        let id = source.id
        Toggle(
          extensions.commands[id]?.manifest.name
            ?? id.replacingOccurrences(of: "extension:", with: "").capitalized,
          isOn: Binding(
            get: { source.enabled },
            set: { enabled in store.change { try $0.setProvider(id, enabled: enabled) } }))
      }
    } header: {
      Text("Sources")
    } footer: {
      Text("Turn off sources you don't use.")
    }
    Section {
      Button("Reveal Extensions Folder") { reveal(extensions.folder.appending(path: "extensions")) }
    }
  }

  private func binding<T>(_ value: T, key: String, group: String? = nil) -> Binding<T> {
    Binding(get: { value }, set: { new in store.change { try $0.set(key, to: new, in: group) } })
  }
  private func reveal(_ folder: URL) { NSWorkspace.shared.open(folder) }
}

@MainActor protocol SettingsActivation {
  func activate(ignoringOtherApps flag: Bool)
}
extension NSApplication: SettingsActivation {}
