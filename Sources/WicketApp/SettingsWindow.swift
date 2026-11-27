import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private let listRoute = SettingsListRoute()
  private let store: ConfigurationStore
  private let extensions: ExtensionHost
  private let clipboard: ClipboardHistory
  private let runs: AgentHistory
  private let updater: Updater?
  private let pauseHotkey: (Bool) -> Void
  private let canOpenMergeConversation: () -> Bool
  private let openMergeConversation: (String) -> Void
  init(
    store: ConfigurationStore, extensions: ExtensionHost, clipboard: ClipboardHistory, runs: AgentHistory,
    updater: Updater?, pauseHotkey: @escaping (Bool) -> Void,
    canOpenMergeConversation: @escaping () -> Bool, openMergeConversation: @escaping (String) -> Void
  ) {
    self.store = store
    self.extensions = extensions
    self.clipboard = clipboard
    self.runs = runs
    self.updater = updater
    self.pauseHotkey = pauseHotkey
    self.canOpenMergeConversation = canOpenMergeConversation
    self.openMergeConversation = openMergeConversation
  }
  func show(section: Int? = nil, list: SettingsListDestination? = nil) {
    if let list { listRoute.request = .init(destination: list) }
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
          updater: updater, pauseHotkey: pauseHotkey, canOpenMergeConversation: canOpenMergeConversation,
          openMergeConversation: openMergeConversation, listRoute: listRoute)
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
      window.setContentSize(SettingsPane.size)
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
  static let size = CGSize(width: 660, height: 480)
  let section: Int
  let store: ConfigurationStore
  let extensions: ExtensionHost
  let clipboard: ClipboardHistory
  let runs: AgentHistory
  let updater: Updater?
  let pauseHotkey: (Bool) -> Void
  var canOpenMergeConversation: () -> Bool = { true }
  var openMergeConversation: (String) -> Void = { _ in }
  var revealExtension: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
  var listRoute: SettingsListRoute?
  @State var entryEditor: SettingsEntryDraft?
  @State private var automaticChecks: Bool?
  @State private var recorder = ShortcutRecorder()
  @State private var transparency = SliderEdit("transparency")
  @State private var blur = SliderEdit("blurRadius")
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginProblem: String?
  @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var confirmingClear = false
  @State private var confirmingClearRuns = false
  /// The Extensions tab's selected source.
  @State var selected: String? = "apps"
  @State private var extensionActionProblem: String?
  @State private var confirmingTrash = false
  /// The local copy as it was when the user asked to trash it.
  @State private var trashing: ExtensionHost.LocalCopy?
  private var config: Configuration { store.configuration }

  var body: some View {
    Group {
      if section == 3 {
        HStack(spacing: 0) {
          extensionList
          Divider()
          ScrollViewReader { scroll in
            form { extensionDetail }.id(selected)
              .task(id: selected) {
                guard let request = listRoute?.request, let list = settingList(for: request.destination),
                  selected == "extension:" + request.destination.folder
                else { return }
                completeListRoute(request, list: list, scroll: scroll)
              }
              .onChange(of: listRoute?.request, initial: true) {
                guard let request = listRoute?.request, let list = settingList(for: request.destination)
                else { return }
                let target = "extension:" + request.destination.folder
                if selected != target {
                  selected = target
                } else {
                  completeListRoute(request, list: list, scroll: scroll)
                }
              }
          }
        }
        .sheet(item: $entryEditor) { draft in
          SettingsEntryEditor(draft: draft, store: store) { entryEditor = nil }
        }
        .onChange(of: entryEditor?.id) { recorder.stop() }
        .onChange(of: selected) {
          recorder.stop()
          extensionActionProblem = nil
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
    .frame(width: Self.size.width, height: Self.size.height)
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
  private var directory: CommandDirectory {
    CommandDirectory(extensions: extensions, hosts: [], store: store)
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
          recorder.record(nil, store: store, pausing: pauseHotkey)
        }
      }
      if recorder.isRecording { recorderHint }
      if let rejection = store.rejection, rejection.target == nil {
        warning(rejection.problem)
      } else if let problem = store.hotkeyProblem {
        warning(problem)
      }
      Picker("Appearance", selection: binding(config.appearance.rawValue, key: "appearance")) {
        ForEach(Configuration.Appearance.allCases, id: \.self) { appearance in
          Text(appearance.rawValue.capitalized).tag(appearance.rawValue)
        }
      }
      Slider(
        value: Binding(
          get: { transparency.value ?? config.transparency }, set: { transparency.value = $0 }),
        in: 0...1,
        step: 0.1
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
        value: Binding(get: { blur.value ?? config.blurRadius }, set: { blur.value = $0 }),
        in: Configuration.blurRadiusRange,
        step: 0.5
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
      Toggle("Only show results when typing", isOn: resultsOnlyWhenTyping)
    }
    let resolutions = extensions.scanned ? directory.hotkeyResolutions() : [:]
    let owners = Set(extensions.ids + ["clipboard"])
    let unavailable = config.hotkeys.filter { binding in
      binding.target.target.map(owners.contains) != true
        && shortcutProblem(for: binding.target, resolution: resolutions[binding.target]) != nil
    }
    if !unavailable.isEmpty {
      Section("Hotkeys") {
        ForEach(unavailable, id: \.target) { binding in
          unavailableHotkeyRow(binding, resolution: resolutions[binding.target])
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
      Toggle(
        "Listen when Wicket opens",
        isOn: binding(config.voice.listenOnOpen, key: "enabled", group: "voice"))
    } footer: {
      Text("Click the microphone to dictate on demand. Start typing to stop listening.")
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
        "Wicket listens to the input chosen in Sound settings and transcribes speech on your Mac. Listening on open uses the Mac's own microphone instead of a Bluetooth headset's; clicking the mic uses the headset. Opening Settings never starts listening or requests permission."
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
      option("Model", key: "model")
      option("Reasoning effort", key: "effort")
      option("Permission mode", key: "mode")
      if AgentOptions.offersFast(config.agent, models: store.models) { option("Speed", key: "speed") }
      Toggle(
        "Stream answers", isOn: binding(config.agent.streamAnswers, key: "streamAnswers", group: "agent"))
    } footer: {
      Text(
        store.discoveryStatus[config.agent.agent.rawValue]
          ?? (store.models.isEmpty
            ? "Loading settings…"
            : "Changes apply on the next turn. Switching agent starts a new conversation."))
    }
    Section {
      answerRetention
    } footer: {
      Text("How long Wicket keeps an idle conversation after you close the launcher.")
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
      Button("Clear History…") { confirmingClearRuns = true }.disabled(!runs.canClear)
        .confirmationDialog("Clear agent history?", isPresented: $confirmingClearRuns) {
          Button("Clear History", role: .destructive) { runs.clear() }
        } message: {
          Text("Deletes every saved run. This can't be undone.")
        }
    }
  }
  private var answerRetention: some View {
    let steps = AgentConfiguration.AnswerRetention.allCases
    let retention = config.agent.answerRetention
    let value = binding(retention.rawValue, key: "answerRetentionSeconds", group: "agent")
    return LabeledContent("Return to search after") {
      HStack {
        Slider(
          value: Binding(
            get: { Double(steps.firstIndex(of: retention)!) },
            set: { value.wrappedValue = steps[Int($0)].rawValue }),
          in: 0...Double(steps.count - 1), step: 1
        ) { Text("Return to search after") }
        .labelsHidden()
        .accessibilityValue(retention.label)
        Text(retention.label)
          .frame(width: 80, alignment: .trailing)
          .accessibilityHidden(true)
      }
    }
  }
  private func option(_ title: String, key: String) -> some View {
    let items = AgentOptions.choices(store.models, key: key, for: config.agent)
    let value = AgentOptions.resolved(config.agent, key: key, models: store.models)
    let saved =
      [
        "model": config.agent.model, "effort": config.agent.effort, "mode": config.agent.mode,
        "speed": config.agent.speed,
      ][key] ?? nil
    return Picker(
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
    .frame(width: 200)
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
      if let icon, ExtensionIcons.fileType(icon) != nil, let command = extensions.commands[id] {
        Label {
          Text(title(id))
        } icon: {
          ExtensionIcon(value: icon, command: command, host: extensions, symbolSize: 13)
            .frame(width: 16, height: 16)
        }
      } else {
        Label(title(id), systemImage: icon ?? "puzzlepiece.extension")
      }
      Spacer()
      if extensions.locations[id]?.shadowsBuiltIn == true {
        Image(systemName: "square.on.square")
          .font(.caption2).foregroundStyle(.secondary)
          .help("A local copy replaces the built-in version")
          .accessibilityLabel("Local copy replaces the built-in version")
      }
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
    let directory = self.directory
    let resolutions = extensions.scanned ? directory.hotkeyResolutions() : [:]
    let command = extensions.commands[id]
    let location = extensions.locations[id]
    let showsCopyActions = location?.shadowsBuiltIn == true || location?.source == .brokenFallback
    if let location, showsCopyActions {
      Section {
        if location.shadowsBuiltIn {
          Label("A local copy replaces the built-in version", systemImage: "square.on.square")
            .font(.callout)
          if let base = location.version, let builtIn = location.builtInVersion, base.precedes(builtIn) {
            Text("Based on \(base.rawValue) · Built-in is \(builtIn.rawValue)").foregroundStyle(.secondary)
          }
        }
        HStack {
          trashButton(id, label: location.shadowsBuiltIn ? "Use Built-in" : "Move to Trash…")
          if location.bundledContract != nil {
            Button("Ask Agent to Merge") { askAgentToMerge(id) }
              .disabled(!canOpenMergeConversation())
              .help(canOpenMergeConversation() ? "Draft a merge request" : "Wait for the current agent turn")
          }
          Button("Show in Finder") { showExtensionInFinder(id) }
        }
      }
    }
    if let about = Self.builtins[id]?.2 ?? command?.manifest.description {
      Section {
      } header: {
        Text(about).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(about)
          .padding(.bottom, 6)
      }
    }
    if let problem = extensions.problems[id] {
      warning(problem.message).textSelection(.enabled)
    }
    if let extensionActionProblem { warning(extensionActionProblem) }
    if id == "clipboard" {
      Section { clipboardRows(enabled: config.isEnabled(id, extensions: [])) }
    }
    if let command {
      let folder = command.folder.lastPathComponent
      let fields = command.manifest.settings.compactMap { setting in
        if case .field(let field) = setting { return field }
        return nil
      }
      if !fields.isEmpty {
        Section("Settings") {
          ForEach(fields, id: \.name) { field in
            let saved = field.savedSettingText(config.extensions[folder]?[field.name])
            SettingField(setting: field, saved: saved) { value in
              store.change { try $0.set(field.name, to: value, forExtension: folder) }
            }
          }
        }
      }
      ForEach(command.manifest.settings.compactMap(\.list), id: \.name) { list in
        entryTable(list, folder: folder, target: id, resolutions: resolutions).id(list.name)
      }
    }
    let targets: [(String, HotkeyTarget)] =
      id == "clipboard"
      ? [(ClipboardHistory.title, HotkeyTarget(target: id))]
      : command.map { command in
        (command.commandHotkeyTarget.map { [(command.manifest.name, $0)] } ?? [])
          + (command.manifest.items ?? []).compactMap { item in
            directory.itemHotkeyTarget(item, in: id).map { (item.title, $0) }
          }
      } ?? []
    let listed = Set(targets.map(\.1))
    let unavailable = config.hotkeys.filter { binding in
      let target = binding.target
      guard target.target == id, !listed.contains(target),
        shortcutProblem(for: target, resolution: resolutions[target]) != nil
      else { return false }
      guard target.entryList != nil, let item = command?.item(for: target) else { return true }
      return directory.itemHotkeyTarget(item, in: id) != target
    }
    if !targets.isEmpty || !unavailable.isEmpty {
      Section("Hotkeys") {
        ForEach(targets, id: \.1) { title, target in
          hotkeyRow(title, target, resolution: resolutions[target])
        }
        ForEach(unavailable, id: \.target) { binding in
          unavailableHotkeyRow(binding, resolution: resolutions[binding.target])
        }
      }
    }
    if !showsCopyActions, location?.localFolder != nil {
      Section {
        HStack {
          Button("Show in Finder") { showExtensionInFinder(id) }
          trashButton(id, label: "Move to Trash…")
        }
        .controlSize(.small)
      }
    }
  }

  func showExtensionInFinder(_ id: String) {
    if let folder = extensions.ownFolder(id) { revealExtension(folder) }
  }

  func askAgentToMerge(_ id: String) {
    guard canOpenMergeConversation(), let location = extensions.locations[id],
      location.shadowsBuiltIn || location.source == .brokenFallback,
      let local = location.localFolder, let builtIn = location.bundledFolder,
      let bundledContract = location.bundledContract
    else { return }
    let name = builtIn.lastPathComponent
    let localContract = location.localContract.map(String.init) ?? "unknown"
    let strategy: String
    if let base = location.version?.rawValue {
      let sources = "https://github.com/pietz/wicket/tree/\(name)/v\(base)/Sources/Extensions/\(name)"
      strategy = """
        My copy is based on version \(base). Find the base sources at \(sources). Resolve shared-source \
        symlinks from the tag before diffing my copy against the base. Apply those changes to the current \
        built-in. If the base sources are unavailable, do a two-way merge.
        """
    } else {
      strategy =
        "My copy’s base version is unknown. Do a two-way merge between my copy and the current built-in."
    }
    let version = location.builtInVersion.map { "Set `version` in `wicket.json` to \($0.rawValue). " } ?? ""
    let wicket = (Bundle.main.executableURL?.path ?? "Wicket").debugDescription
    recorder.stop()
    openMergeConversation(
      """
      Please merge my local Wicket extension at \(local.path.debugDescription) (contract \(localContract)) \
      onto the current built-in version at \(builtIn.path.debugDescription) (contract \(bundledContract)). \
      Read the extension contract first. \(strategy) Keep my customizations, the built-in’s current \
      features, and my saved settings and hotkeys. Write the merge to my local folder. \(version)Rebuild, \
      then run `\(wicket) --diagnose extensions` to verify the discovery error is gone and `activeFolder` \
      is my local copy. Exercise the customized behavior with `\(wicket) --extension \(name)`.
      """)
  }
  private func completeListRoute(
    _ request: SettingsListRoute.Request, list: SettingList, scroll: ScrollViewProxy
  ) {
    scroll.scrollTo(list.name, anchor: .top)
    let destination = request.destination
    if let values = destination.values {
      entryEditor = .init(folder: destination.folder, list: list, values: values)
    }
    listRoute?.request = nil
  }

  private func settingList(for destination: SettingsListDestination) -> SettingList? {
    extensions.commands["extension:" + destination.folder]?.manifest.settings
      .first { $0.name == destination.setting }?.list
  }

  private func entryTable(
    _ list: SettingList, folder: String, target: String,
    resolutions: [HotkeyTarget: HotkeyRegistrations.Resolution]
  ) -> some View {
    let entries = config.extensions[folder].map { list.read($0[list.name]).entries } ?? []
    let rows = entries.map { entry in
      (entry, list.row(entry).flatMap { directory.itemHotkeyTarget($0, in: target) })
    }
    let hasHotkeys = rows.contains { $0.1 != nil }
    return Section {
      if entries.isEmpty {
        Text("No entries").foregroundStyle(.secondary)
      } else {
        HStack {
          Text("Title").frame(maxWidth: .infinity, alignment: .leading)
          if hasHotkeys { Text("Hotkey").frame(width: 134) }
          Color.clear.frame(width: 54, height: 1)
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(rows, id: \.0) { entry, binding in
        if let id = entry["id"] {
          let title = list.title(entry)
          VStack(alignment: .leading) {
            HStack {
              Text(title).lineLimit(1).help(title).frame(maxWidth: .infinity, alignment: .leading)
              if hasHotkeys {
                Group {
                  if let binding {
                    shortcutControls(binding)
                  } else {
                    Color.clear
                  }
                }
                .frame(width: 134)
              }
              Button("Edit", systemImage: "pencil") {
                entryEditor = .init(folder: folder, list: list, values: entry, entryID: id)
              }
              .help("Edit \(title)")
              Button("Delete", systemImage: "trash") {
                recorder.stop()
                store.change { try $0.changeEntry(in: list, folder: folder, id: id, values: nil) }
              }
              .help("Delete \(title)")
            }
            .labelStyle(.iconOnly).controlSize(.small)
            if let binding { shortcutFeedback(for: binding, resolution: resolutions[binding]) }
          }
        }
      }
    } header: {
      HStack {
        Text(list.description)
        Spacer()
        if list.addable {
          Button("Add \(list.entryName)", systemImage: "plus") {
            entryEditor = .init(folder: folder, list: list)
          }
          .labelStyle(.iconOnly)
        }
      }
    }
  }

  /// The user's own extension goes to the Trash, so it can be put back. With no bundled one of its name
  /// to take its place, the selection moves to a neighbour.
  private func trashButton(_ id: String, label: String) -> some View {
    let restores = extensions.locations[id]?.bundledFolder != nil
    let retired = extensions.locations[id]?.source == .retired
    let item = restores ? "the \(retired ? "old" : "local") copy of “\(title(id))”" : "“\(title(id))”"
    return Button(label) {
      trashing = extensions.locations[id]?.localCopy
      confirmingTrash = true
    }
    .disabled(store.problem != nil)
    .confirmationDialog("Move \(item) to the Trash?", isPresented: $confirmingTrash) {
      Button("Move to Trash", role: .destructive) {
        extensionActionProblem = nil
        do { try trashExtension(id, confirmed: trashing) } catch {
          extensionActionProblem = error.localizedDescription
        }
      }
    } message: {
      if restores {
        Text("Wicket will use the built-in with your saved settings and hotkeys.")
      } else {
        Text("Your settings and hotkeys stay in config.json. You can restore the extension from the Trash.")
      }
    }
  }
  func trashExtension(_ id: String, confirmed: ExtensionHost.LocalCopy?) throws {
    try extensions.trash(id, confirmed: confirmed)
    guard extensions.locations[id]?.bundledFolder == nil else { return }
    let others = extensionSources(config.sources(extensions: extensions.ids)).map(\.id)
    let index = others.firstIndex(of: id) ?? 0
    selected = others.dropFirst(index + 1).first ?? others.prefix(index).last ?? "apps"
  }
  private func hotkeyRow(
    _ title: String, _ target: HotkeyTarget, resolution: HotkeyRegistrations.Resolution?
  ) -> some View {
    VStack(alignment: .leading) {
      LabeledContent(title) { shortcutControls(target) }
      shortcutFeedback(for: target, resolution: resolution)
    }
  }

  func shortcutProblem(for target: HotkeyTarget, resolution: HotkeyRegistrations.Resolution?) -> String? {
    if let rejection = store.rejection, rejection.target == target { return rejection.problem }
    if let registration = store.bindingFailures[target], let problem = registration.problem {
      if let inEffect = registration.inEffect, let old = try? Shortcut(inEffect) {
        return "\(problem) \(old.symbols) still works."
      }
      return problem
    }
    guard let resolution, resolution != .ok else { return nil }
    return "Hotkey unavailable: \(resolution.rawValue)."
  }

  @ViewBuilder private func shortcutFeedback(
    for target: HotkeyTarget, resolution: HotkeyRegistrations.Resolution?
  ) -> some View {
    if recorder.target == target { recorderHint }
    if let problem = shortcutProblem(for: target, resolution: resolution) { warning(problem) }
  }

  private func shortcutControls(_ target: HotkeyTarget) -> some View {
    let keys = config.hotkeys.first { $0.target == target }?.keys
    return HStack(spacing: 4) {
      if keys != nil {
        Button("Remove Hotkey", systemImage: "xmark.circle.fill") { store.bind(nil, to: target) }
          .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
      }
      shortcutButton(keys?.symbols ?? "Record Hotkey", recording: recorder.target == target, minWidth: 110) {
        recorder.record(target, store: store, pausing: pauseHotkey)
      }
    }
  }
  private func unavailableHotkeyRow(
    _ binding: Configuration.Hotkey, resolution: HotkeyRegistrations.Resolution?
  ) -> some View {
    VStack(alignment: .leading) {
      LabeledContent(binding.target.description) {
        Text(binding.keys.symbols)
        Button("Remove") { store.bind(nil, to: binding.target) }
      }
      shortcutFeedback(for: binding.target, resolution: resolution)
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
    Button("Clear History…") { confirmingClear = true }.disabled(!clipboard.canClear)
      .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
        Button("Clear History", role: .destructive) { clipboard.clear() }
      } message: {
        Text("Deletes every saved text and image. This can't be undone.")
      }
  }
  private static func megabytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  var resultsOnlyWhenTyping: Binding<Bool> {
    binding(config.resultsOnlyWhenTyping, key: "resultsOnlyWhenTyping")
  }

  private func binding<T>(_ value: T, key: String, group: String? = nil) -> Binding<T> {
    Binding(get: { value }, set: { new in store.change { try $0.set(key, to: new, in: group) } })
  }
  private func reveal(_ folder: URL) { NSWorkspace.shared.open(folder) }
}

/// One of an extension's settings: saved on Return or when the field loses focus, and removed when emptied,
/// so the manifest's default, shown as the prompt, applies again.
private struct SettingField: View {
  let setting: Field
  let saved: String?
  let save: (String?) -> Void
  @State private var draft: String?
  @FocusState private var focused: Bool
  var body: some View {
    let value = Binding<String?>(
      get: { draft ?? saved },
      set: { value in
        if setting.inSearchBar { draft = value ?? "" } else { saveOverride(value) }
      })
    SettingControl(field: setting, value: value)
      .focused($focused)
      .onSubmit(commit)
      .onChange(of: focused) { if !focused { commit() } }
      .onDisappear(perform: commit)
    if let draft, !draft.isEmpty, setting.canonical(draft) == nil {
      Text(
        setting.min == nil && setting.max == nil && setting.step == nil
          ? "Enter a number using a decimal point." : "Enter a number within the allowed range and step."
      ).foregroundStyle(.red)
    }
  }
  private func commit() {
    guard let value = draft, value.isEmpty || setting.canonical(value) != nil else { return }
    draft = nil
    if value != saved ?? "" { saveOverride(value.isEmpty ? nil : value) }
  }
  private func saveOverride(_ value: String?) {
    let standard = setting.default.flatMap(setting.canonical)
    save(value.flatMap(setting.canonical) == standard ? nil : value)
  }
}

private struct SettingControl: View {
  let field: Field
  @Binding var value: String?
  var editingEntry = false
  private var label: String { field.title }
  private var text: Binding<String> { Binding(get: { value ?? "" }, set: { value = $0 }) }
  private var choice: Binding<String?> {
    Binding(get: { value.flatMap { field.canonical($0) != nil ? $0 : nil } }, set: { value = $0 })
  }

  var body: some View {
    Group {
      switch field.type {
      case .bool where editingEntry && field.optional == true:
        Picker(label, selection: choice) {
          Text("Unset").tag(nil as String?)
          Text("On").tag(Optional("true"))
          Text("Off").tag(Optional("false"))
        }
      case .bool:
        Toggle(
          label,
          isOn: Binding(
            get: { (choice.wrappedValue ?? field.default) == "true" },
            set: { value = $0 ? "true" : "false" }
          )
        ).toggleStyle(.switch)
      case .choice:
        let filtersApps = !editingEntry && field.options?.contains { $0.requiresApp != nil } == true
        let options =
          filtersApps
          ? field.availableOptions { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
          : field.options ?? []
        let defaultOption = options.first { $0.value == field.default }
        let selection =
          filtersApps
          ? Binding(
            get: { options.first { $0.value == value }?.value ?? defaultOption?.value },
            set: { value = $0 == defaultOption?.value ? nil : $0 }
          )
          : choice
        Picker(label, selection: selection) {
          if editingEntry {
            if field.optional == true {
              Text("Unset").tag(nil as String?)
            } else if choice.wrappedValue == nil {
              Text("Choose…").tag(nil as String?)
            }
          } else if !filtersApps || defaultOption == nil {
            Text(defaultOption.map { "Default (\($0.label))" } ?? "Unset").tag(nil as String?)
          }
          ForEach(options, id: \.value) { Text($0.label).tag(Optional($0.value)) }
        }
      case .text where field.multiline == true:
        VStack(alignment: .leading, spacing: 4) {
          Text(label)
          TextEditor(text: text)
            .frame(minHeight: 72)
            .padding(4)
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary) }
            .accessibilityLabel(label)
        }
      case .text, .number:
        if editingEntry {
          LabeledContent(label) {
            TextField("", text: text).accessibilityLabel(label).textFieldStyle(.roundedBorder)
          }
        } else {
          TextField(label, text: text, prompt: field.default.map { Text($0) })
        }
      }
    }
    .help(field.description ?? "")
  }
}

@MainActor protocol SettingsActivation {
  func activate(ignoringOtherApps flag: Bool)
}
extension NSApplication: SettingsActivation {}

struct SettingsListDestination: Equatable {
  let folder: String
  let setting: String
  var values: [String: String]?

  init(folder: String, setting: String, values: [String: String]? = nil) {
    self.folder = folder
    self.setting = setting
    self.values = values
  }
  init?(path: String) {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
    self.init(folder: String(parts[0]), setting: String(parts[1]))
  }
}

@MainActor @Observable final class SettingsListRoute {
  struct Request: Equatable {
    let id = UUID()
    let destination: SettingsListDestination
  }
  var request: Request?
}

struct SettingsEntryDraft: Identifiable {
  let id = UUID()
  let folder: String
  let list: SettingList
  var values: [String: String] = [:]
  var entryID: String?

  var initialValues: [String: String] { entryID == nil ? list.valuesForNewEntry(values) : values }
}

struct SettingsEntryEditor: View {
  static func size(for list: SettingList) -> CGSize {
    let fields = list.editableFields
    let regularHeight: CGFloat = fields.count > 4 ? 400 : 350
    return CGSize(width: 420, height: fields.contains(where: { $0.multiline == true }) ? 425 : regularHeight)
  }
  let draft: SettingsEntryDraft
  let store: ConfigurationStore
  let close: () -> Void
  @State private var values: [String: String]

  init(draft: SettingsEntryDraft, store: ConfigurationStore, close: @escaping () -> Void) {
    self.draft = draft
    self.store = store
    self.close = close
    _values = State(initialValue: draft.initialValues)
  }

  private func numberProblem(_ field: Field) -> String? {
    guard field.type == .number, let value = values[field.name], field.canonical(value) == nil else {
      return nil
    }
    guard let number = Field.number(value) else { return "Enter a number using a decimal point." }
    if let min = field.min, let max = field.max, !(min...max).contains(number) {
      return "Enter a number from \(Field.wire(min)) to \(Field.wire(max))."
    }
    if let min = field.min, number < min { return "Enter at least \(Field.wire(min))." }
    if let max = field.max, number > max { return "Enter at most \(Field.wire(max))." }
    return "Enter a number that matches the allowed step."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\(draft.entryID == nil ? "Add" : "Edit") \(draft.list.entryName)").font(.headline).padding()
      Form {
        ForEach(draft.list.editableFields, id: \.name) { field in
          VStack(alignment: .leading, spacing: 4) {
            SettingControl(
              field: field,
              value: Binding(
                get: { values[field.name] },
                set: { values[field.name] = $0?.isEmpty == false ? $0 : nil }
              ), editingEntry: true)
            if let description = field.description, description != field.title {
              Text(description).font(.callout).foregroundStyle(.secondary)
            }
            if let problem = numberProblem(field) {
              Text(problem).font(.callout).foregroundStyle(.red)
            }
          }
        }
        if draft.list.accepts(values), let problem = draft.list.urlProblem(values) {
          Text(problem).foregroundStyle(.red)
        }
        if let problem = store.writeProblem { Text(problem).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
        Button("Save") {
          if store.change({
            try $0.changeEntry(
              in: draft.list, folder: draft.folder, id: draft.entryID ?? draft.id.uuidString.lowercased(),
              values: values, original: draft.entryID == nil ? nil : draft.values,
              inserting: draft.entryID == nil)
          }) {
            close()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!draft.list.accepts(values) || draft.list.urlProblem(values) != nil)
      }
      .buttonStyle(.bordered)
      .padding()
    }
    .frame(width: Self.size(for: draft.list).width, height: Self.size(for: draft.list).height)
    .background(.background)
  }
}
