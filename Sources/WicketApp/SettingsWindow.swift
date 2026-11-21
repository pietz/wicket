import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private let store: ConfigurationStore
  private let extensions: ExtensionHost
  private let clipboard: ClipboardHistory
  private let runs: AgentHistory
  private let updater: Updater?
  private let pauseHotkey: (Bool) -> Void
  init(
    store: ConfigurationStore, extensions: ExtensionHost, clipboard: ClipboardHistory, runs: AgentHistory,
    updater: Updater?, pauseHotkey: @escaping (Bool) -> Void
  ) {
    self.store = store
    self.extensions = extensions
    self.clipboard = clipboard
    self.runs = runs
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
        ("Agent", "sparkles"), ("Extensions", "puzzlepiece.extension"),
      ].enumerated() {
        let pane = SettingsPane(
          section: index, store: store, extensions: extensions, clipboard: clipboard, runs: runs,
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
  let clipboard: ClipboardHistory
  let runs: AgentHistory
  let updater: Updater?
  let pauseHotkey: (Bool) -> Void
  @State private var automaticChecks: Bool?
  @State private var recorder = ShortcutRecorder()
  @State private var transparency = SliderEdit("backgroundTransparency")
  @State private var blur = SliderEdit("blur")
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginProblem: String?
  @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var confirmingClear = false
  @State private var confirmingClearRuns = false
  /// The Extensions tab's selected source.
  @State var selected: String? = "apps"
  @State private var copyProblem: String?
  @State private var confirmingTrash = false
  private var config: Configuration { store.configuration }

  var body: some View {
    Group {
      if section == 3 {
        HStack(spacing: 0) {
          extensionList
          Divider()
          form { extensionDetail }.id(selected)
        }
        .onChange(of: selected) {
          recorder.stop()
          copyProblem = nil
        }
      } else {
        form {
          switch section {
          case 0: general
          case 1: voice
          default: agent
          }
        }
      }
    }
    .frame(width: 560, height: 480)
    .onAppear {
      if section == 2 { store.discoverOptions() }
    }
    .onChange(of: config.agent.agent) { if section == 2 { store.discoverOptions() } }
    .onDisappear { recorder.stop() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      loginStatus = SMAppService.mainApp.status
      microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }
  }

  private func form(@ViewBuilder _ content: () -> some View) -> some View {
    Form {
      if let problem = store.problem {
        Section {
          warning(problem)
          Text("Keeping the last good configuration. Fix config.json to continue editing.")
          Button("Open Config Folder") { reveal(store.url.deletingLastPathComponent()) }
        }
      }
      if let problem = store.writeProblem { warning(problem) }
      Group { content() }.disabled(store.problem != nil)
    }
    .formStyle(.grouped)
  }
  private var recorderHint: some View {
    Text(
      recorder.rejected ? "Add ⌘, ⌃ or ⌥ (F-keys work alone). Esc cancels." : "Press a shortcut. Esc cancels."
    )
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var general: some View {
    Section {
      LabeledContent("Open Wicket") {
        shortcutButton(config.hotkey.symbols, recording: recorder.isRecording, minWidth: 120) {
          recorder.start(pausing: pauseHotkey) { store.setHotkey($0) }
        }
      }
      if recorder.isRecording { recorderHint }
      if let problem = store.hotkeyProblem { warning(problem) }
      Picker("Appearance", selection: binding(config.appearance.rawValue, key: "appearance")) {
        ForEach(Configuration.Appearance.allCases, id: \.self) { appearance in
          Text(appearance.rawValue.capitalized).tag(appearance.rawValue)
        }
      }
      Slider(
        value: Binding(
          get: { transparency.value ?? config.backgroundTransparency }, set: { transparency.value = $0 }),
        in: 0...1
      ) {
        Text("Transparency")
      } minimumValueLabel: {
        Text("Solid")
      } maximumValueLabel: {
        Text("Clear")
      } onEditingChanged: { editing in
        transparency.editingChanged(editing, store: store)
      }
      Slider(
        value: Binding(get: { blur.value ?? config.blur }, set: { blur.value = $0 }),
        in: Configuration.blurRange
      ) {
        Text("Blur")
      } minimumValueLabel: {
        Text("Sharp")
      } maximumValueLabel: {
        Text("Soft")
      } onEditingChanged: { editing in
        blur.editingChanged(editing, store: store)
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
      LabeledContent("Permission", value: microphoneText)
      Button("Open Microphone Settings") {
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
      }
    } header: {
      Text("Microphone")
    } footer: {
      Text(
        "Wicket listens to the input chosen in Sound settings, using the Mac's own microphone instead of a Bluetooth headset's, and transcribes speech on your Mac. Opening Settings never starts listening or requests permission."
      )
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
      described("Show answers as they arrive. Turn off for completed steps.") {
        Toggle(
          "Stream answers", isOn: binding(config.agent.streamAnswers, key: "streamAnswers", group: "agent"))
      }
    } footer: {
      Text(
        store.discoveryStatus[config.agent.agent.rawValue]
          ?? (store.models.isEmpty
            ? "Loading settings…"
            : "Changes apply on the next turn. Switching agent starts a new conversation."))
    }
    Section(config.agent.agent.product) {
      let agent = config.agent.agent
      if AgentCLI.installed(agent) {
        let (status, hint): (String, String?) =
          switch store.signIn[agent] {
          case .signedIn: ("is installed and signed in", nil)
          case .signedOut: ("isn't signed in", "Run \(agent.signIn) in Terminal.")
          case .unknown:
            ("is installed", "Couldn't check sign-in. Run \(agent.rawValue) in Terminal to see why.")
          case nil: ("is installed", "Checking sign-in…")
          }
        Label(
          "\(agent.product) \(status)",
          systemImage: store.signIn[agent] == .signedOut ? "exclamationmark.triangle" : "checkmark.circle")
        if let hint { Text(hint).textSelection(.enabled).foregroundStyle(.secondary) }
      } else {
        Text(
          "\(config.agent.agent.product) isn't installed. Install it, then run \(config.agent.agent.signIn) in Terminal."
        )
        .textSelection(.enabled).font(.callout)
      }
    }
    Section(AgentHistory.title) {
      Text(
        "Keeps your last \(AgentHistory.maxEntries) agent runs for \(AgentHistory.maxDays) days, only on this Mac, outside the agent's working folder; what the agent can read follows its permission mode. Type history to reopen one and follow up."
      )
      .font(.callout).foregroundStyle(.secondary)
      LabeledContent("Saved runs", value: "\(runs.runs.count)")
      Button("Clear History…") { confirmingClearRuns = true }.disabled(runs.runs.isEmpty)
        .confirmationDialog("Clear agent history?", isPresented: $confirmingClearRuns) {
          Button("Clear History", role: .destructive) { runs.clear() }
        } message: {
          Text("Deletes every saved run. This can't be undone.")
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
    return described(help) {
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
    }
  }
  /// A control with its explanation under it.
  private func described(_ help: String, @ViewBuilder _ control: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      control()
      Text(help).font(.callout).foregroundStyle(.secondary)
    }
  }
  private func warning(_ problem: String) -> some View {
    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
  }

  // MARK: Extensions

  private static let builtins = [
    "apps": ("Apps", "square.grid.2x2", "Finds the apps on this Mac by name."),
    "files": ("Files", "doc", "Finds files by name with Spotlight, from two characters on."),
    "clipboard": (
      ClipboardHistory.title, "doc.on.clipboard", "Keeps the texts and images you copy to paste them again."
    ),
  ]
  private func title(_ id: String) -> String {
    Self.builtins[id]?.0 ?? extensions.commands[id]?.manifest.name ?? String(id.dropFirst("extension:".count))
  }
  private var extensionList: some View {
    let sources = config.sources(extensions: extensions.ids)
    return List(selection: $selected) {
      Section("Built in") {
        ForEach(sources.filter { Self.builtins[$0.id] != nil }, id: \.id, content: sourceRow)
      }
      Section("Extensions") {
        ForEach(extensionSources(sources), id: \.id, content: sourceRow)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      Button("Extensions Folder") { reveal(extensions.folder.appending(path: "extensions")) }.padding(10)
    }
    .frame(width: 220)
  }
  private func extensionSources(_ sources: [Configuration.ProviderEntry]) -> [Configuration.ProviderEntry] {
    sources.filter { Self.builtins[$0.id] == nil }.sorted { title($0.id) < title($1.id) }
  }
  private func sourceRow(_ source: Configuration.ProviderEntry) -> some View {
    let id = source.id
    let icon =
      extensions.problems[id] != nil
      ? "exclamationmark.triangle" : Self.builtins[id]?.1 ?? extensions.commands[id]?.manifest.icon
    return HStack {
      Label(title(id), systemImage: icon ?? "puzzlepiece.extension")
      Spacer()
      Toggle(
        title(id),
        isOn: Binding(
          get: { source.enabled },
          set: { enabled in store.change { try $0.setProvider(id, enabled: enabled) } })
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(store.problem != nil)
    }
    .tag(id)
  }
  @ViewBuilder private var extensionDetail: some View {
    let id = selected ?? "apps"
    let command = extensions.commands[id]
    let bundled = command.map(extensions.isBundled) ?? false
    let own = extensions.ownFolder(id) != nil
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(title(id)).font(.title3.bold())
        if let about = Self.builtins[id]?.2 ?? command?.manifest.description {
          Text(about).foregroundStyle(.secondary)
        }
      }
      if let problem = extensions.problems[id] {
        warning(problem).textSelection(.enabled)
      }
      if command != nil || own {
        HStack {
          if let command {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([command.folder]) }
          }
          if let command, bundled {
            Button("Make It Mine") {
              copyProblem = nil
              do { try extensions.makeMine(command) } catch { copyProblem = error.localizedDescription }
            }
            .help("Copies it into your extensions folder, where you and your agent can change it.")
          }
          if own { trashButton(id) }
        }
        if let copyProblem { Text(copyProblem).foregroundStyle(.red) }
      }
    } footer: {
      if bundled { Text("Bundled with Wicket. A copy made yours replaces it.") }
    }
    if id == "clipboard" {
      Section { clipboardRows(enabled: config.isEnabled(id, extensions: [])) }
    }
    if let command, !command.manifest.settings.isEmpty {
      let folder = command.folder.lastPathComponent
      Section("Settings") {
        ForEach(command.manifest.settings, id: \.name) { setting in
          SettingField(setting: setting, saved: config.extensions[folder]?[setting.name]) { value in
            store.change { try $0.set(setting.name, to: value, forExtension: folder) }
          }
        }
      }
    }
    let targets: [(String, HotkeyTarget)] =
      id == "clipboard"
      ? [(ClipboardHistory.title, HotkeyTarget(target: id))]
      : command.map { command in
        [(command.manifest.name, HotkeyTarget(target: id))]
          + (command.manifest.items ?? []).map { ($0.title, HotkeyTarget(target: id, item: $0.id)) }
      } ?? []
    if !targets.isEmpty {
      Section("Hotkeys") {
        ForEach(targets, id: \.1) { hotkeyRow($0.0, $0.1) }
        if recorder.target != nil { recorderHint }
        if let problem = store.bindingProblem { warning(problem) }
      }
    }
  }
  /// The user's own extension goes to the Trash, so it can be put back. With no bundled one of its name
  /// to take its place, what config.json keeps only for it goes too, and the selection moves to a neighbour.
  private func trashButton(_ id: String) -> some View {
    let name = String(id.dropFirst("extension:".count))
    let restores = extensions.hasBundled(name)
    return Button("Move to Trash…") { confirmingTrash = true }
      .disabled(store.problem != nil)
      .confirmationDialog("Move “\(title(id))” to the Trash?", isPresented: $confirmingTrash) {
        Button("Move to Trash", role: .destructive) {
          let others = extensionSources(config.sources(extensions: extensions.ids)).map(\.id)
          copyProblem = nil
          do { try extensions.trash(id) } catch {
            copyProblem = error.localizedDescription
            return
          }
          guard !restores else { return }
          store.change { try $0.forget(extension: name) }
          let index = others.firstIndex(of: id) ?? 0
          selected = others.dropFirst(index + 1).first ?? others.prefix(index).last ?? "apps"
        }
      } message: {
        Text(
          restores
            ? "The built-in version comes back in its place, with your settings and hotkeys. You can restore your copy from the Trash."
            : "Its settings and hotkeys are removed too. You can restore the folder from the Trash.")
      }
  }
  private func hotkeyRow(_ title: String, _ target: HotkeyTarget) -> some View {
    let keys = config.hotkeys.first { $0.target == target }?.keys
    return LabeledContent(title) {
      if keys != nil {
        Button("Remove Hotkey", systemImage: "xmark.circle.fill") { store.bind(nil, to: target) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
      }
      shortcutButton(keys?.symbols ?? "Record Hotkey", recording: recorder.target == target, minWidth: 110) {
        recorder.record(target, store: store, pausing: pauseHotkey)
      }
    }
  }
  /// A shortcut's button: it shows the keys, and a press starts recording or, while recording, stops it.
  private func shortcutButton(
    _ keys: String, recording: Bool, minWidth: CGFloat, start: @escaping () -> Void
  ) -> some View {
    Button {
      if recording { recorder.stop() } else { start() }
    } label: {
      Text(recording ? "Press a shortcut…" : keys).frame(minWidth: minWidth)
    }
  }
  @ViewBuilder private func clipboardRows(enabled: Bool) -> some View {
    Text(
      "Keeps the last \(ClipboardHistory.maxEntries) texts and images you copy for \(ClipboardHistory.maxDays) days, only on this Mac, outside the agent's working folder; what the agent can read follows its permission mode. Skips anything password managers mark as concealed and images over \(Self.megabytes(ClipboardHistory.imageLimits.each)); past \(Self.megabytes(ClipboardHistory.imageLimits.total)) of images, the oldest go. Type clip to search it."
    )
    .font(.callout).foregroundStyle(.secondary)
    if enabled, !clipboard.readable {
      Label(
        "macOS asks before Wicket reads the clipboard. Allow Wicket under Paste from Other Apps in Privacy & Security.",
        systemImage: "exclamationmark.triangle")
    }
    LabeledContent("Saved clips", value: "\(clipboard.clips.count)")
    LabeledContent("Image storage", value: Self.megabytes(clipboard.imageBytes))
    Button("Clear History…") { confirmingClear = true }.disabled(clipboard.clips.isEmpty)
      .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
        Button("Clear History", role: .destructive) { clipboard.clear() }
      } message: {
        Text("Deletes every saved text and image. This can't be undone.")
      }
  }
  private static func megabytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func binding<T>(_ value: T, key: String, group: String? = nil) -> Binding<T> {
    Binding(get: { value }, set: { new in store.change { try $0.set(key, to: new, in: group) } })
  }
  private func reveal(_ folder: URL) { NSWorkspace.shared.open(folder) }
}

/// One of an extension's settings: saved on Return or when the field loses focus, and removed when emptied,
/// so the manifest's default, shown as the prompt, applies again.
private struct SettingField: View {
  let setting: ExtensionManifest.Argument
  let saved: String?
  let save: (String?) -> Void
  @State private var draft: String?
  @FocusState private var focused: Bool
  var body: some View {
    TextField(
      setting.placeholder ?? setting.name, text: Binding(get: { draft ?? saved ?? "" }, set: { draft = $0 }),
      prompt: setting.default.map { Text($0) }
    )
    .focused($focused)
    .onSubmit(commit)
    .onChange(of: focused) { if !focused { commit() } }
    .onDisappear(perform: commit)
  }
  private func commit() {
    guard let value = draft else { return }
    draft = nil
    if value != saved ?? "" { save(value.isEmpty ? nil : value) }
  }
}

@MainActor protocol SettingsActivation {
  func activate(ignoringOtherApps flag: Bool)
}
extension NSApplication: SettingsActivation {}
