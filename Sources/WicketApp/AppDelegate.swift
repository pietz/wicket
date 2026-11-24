import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  private var palette: PaletteController!
  private var configuration: ConfigurationStore!
  private lazy var hotkey = HotKeyRegistration { [weak self] shortcut in
    HotKey(
      keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue,
      handler: { [weak self] time in self?.palette.toggle(eventTime: time) })
  }
  /// `hotkeys` in config.json, registered beside the launcher's and pressed through the palette.
  private lazy var bindings = CommandHotKeys { shortcut, press in
    HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.rawValue, handler: { _ in press() })
  }
  private var settings: SettingsWindowController?
  private var status: NSStatusItem!
  private var shortcutItem: NSMenuItem!
  private var updater: Updater?
  /// URLs AppKit delivered before setup, which can happen on a cold launch; nil once set up.
  private var launchURLs: [URL]? = []

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let directory = Edition.current.configDirectory()
    let history = UsageHistory(url: directory.appending(path: "usage.json"))
    let apps = AppsProvider()
    let clipboard = ClipboardHistory(
      url: Edition.current.privateDirectory().appending(path: "clipboard-history.json"))
    let runs = AgentHistory(url: Edition.current.privateDirectory().appending(path: "agent-history.json"))
    let updater = Updater()
    self.updater = updater
    let runtime = RuntimeRecorder(url: RuntimeRecord.url(beside: AgentLog.standard()))
    let model = LauncherModel(
      apps: apps, files: FilesProvider(), clipboard: clipboard, agentHistory: runs,
      history: history, folder: directory, extensionDataDirectory: Edition.current.extensionDataDirectory(),
      availableUpdate: { updater?.availableUpdate }, checkForUpdates: { updater?.checkForUpdates() },
      runtime: runtime)
    do {
      try AnswerRenderer.installFiles(in: directory)
      try ExtensionHost.installFiles(in: directory)
    } catch {
      model.installProblem = error.localizedDescription
    }
    configuration = model.store
    configuration.applyHotkey = { [weak self] in self?.hotkey.apply($0) }
    configuration.applyBinding = { [weak self] keys, target in
      guard let self else { return nil }
      return bindings.set(keys, for: target, launcher: hotkey.inEffect)
    }
    bindings.onPress = { [weak self] in self?.palette.model.press($0) }
    let register: (Configuration) -> Void = { [weak self] config in
      guard let self else { return }
      configuration.hotkeyProblem = hotkey.apply(config.hotkey)
      configuration.bindingProblem = bindings.apply(config.hotkeys, launcher: hotkey.inEffect)
      runtime.register(
        HotkeyRegistrations(
          launcher: hotkey.snapshot(config.hotkey, problem: configuration.hotkeyProblem),
          bindings: bindings.latest))
    }
    // Either recorder, Settings' or the panel's Set Hotkey…, pauses every hotkey, so it hears the keys.
    let pause: (Bool) -> Void = { [weak self] paused in
      guard let self else { return }
      hotkey.pause(paused)
      bindings.pause(paused)
      if !paused { register(configuration.configuration) }
    }
    settings = SettingsWindowController(
      store: configuration, extensions: model.extensions, clipboard: clipboard, runs: runs, updater: updater,
      pauseHotkey: pause)
    palette = PaletteController(model: model, settings: settings, pauseHotkeys: pause)
    apps.onChange = { [weak model] in model?.navigator.sourcesChanged([apps.id]) }
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let name = Edition.current.name
    let menu = NSMenu()
    shortcutItem = menu.addItem(
      withTitle: "Open \(name)", action: #selector(show), keyEquivalent: "")
    shortcutItem.target = self
    let settingsItem = menu.addItem(
      withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    let folder = menu.addItem(
      withTitle: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: "")
    folder.target = self
    if updater != nil {
      menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        .target = self
    }
    menu.addItem(.separator())
    let quit = menu.addItem(withTitle: "Quit \(name)", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    status.menu = menu
    let appMenu = NSMenu()
    let root = NSMenuItem()
    root.submenu = menu.copy() as? NSMenu
    appMenu.addItem(root)
    let windows = NSMenu(title: "Window")
    windows.addItem(
      withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let windowItem = NSMenuItem()
    windowItem.submenu = windows
    appMenu.addItem(windowItem)
    NSApp.mainMenu = appMenu
    let updateAction = #selector(checkForUpdates)
    let updateItems = [menu, root.submenu].compactMap { $0?.items.first { $0.action == updateAction } }
    Task { [weak self] in
      for await (waiting, version) in Observations({ (model.agent.waiting, updater?.availableUpdate) }) {
        self?.status.button?.image = Self.statusImage(name: name, dot: waiting || version != nil)
        let title = version.map { "Update to \($0)…" } ?? "Check for Updates…"
        for item in updateItems { item.title = title }
      }
    }
    // The app's one reaction to a configuration load, in order: the services (and through the screens'
    // redraw, voice), then the hotkey registrations, then the status item.
    var applied = Configuration()
    configuration.onChange = { [weak self] config in
      guard let self else { return }
      NSApp.appearance = config.appearance.nsAppearance
      model.apply(config)
      if config != applied || hotkey.inEffect == nil {
        applied = config
        register(config)
        shortcutItem.title = "Open \(name) (\(hotkey.inEffect?.symbols ?? "menu"))"
      }
      // Only what lasts: it is set when a configuration loads, so a recording's rejection would stay.
      status.button?.toolTip =
        configuration.problem ?? configuration.hotkeyProblem ?? configuration.bindingProblem
        ?? model.installProblem ?? "\(name): \(hotkey.inEffect?.symbols ?? "use menu to open")"
    }
    runtime.refreshPermissions(model.extensions.permissions)
    configuration.start()
    model.extensions.start()
    Task { await apps.start() }
    palette.showOnLaunch(NSAppleEventManager.shared().currentAppleEvent, opening: launchURLs ?? [])
    launchURLs = nil
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    palette.show()
    return true
  }

  public func application(_ application: NSApplication, open urls: [URL]) {
    guard launchURLs == nil else {
      launchURLs?.append(contentsOf: urls)
      return
    }
    for url in urls { palette.open(url) }
  }

  /// The menu bar icon, with a dot at its top right while something waits for the user. Drawn, since
  /// this symbol has no badged variant; a template, so the menu bar tints the dot with the icon.
  private static func statusImage(name: String, dot: Bool) -> NSImage? {
    guard
      let symbol = NSImage(
        systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: name)
    else { return nil }
    guard dot else { return symbol }
    let image = NSImage(size: symbol.size, flipped: false) { bounds in
      symbol.draw(in: bounds)
      let dot = NSRect(x: bounds.maxX - 6, y: bounds.maxY - 6, width: 6, height: 6)
      // A clear ring keeps the dot apart from the symbol under it.
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      NSBezierPath(ovalIn: dot).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "\(name), something is waiting"
    return image
  }

  @objc private func show() { palette.show() }
  @objc private func showSettings() { palette.showSettings() }
  @objc private func openConfigFolder() {
    NSWorkspace.shared.open(configuration.url.deletingLastPathComponent())
  }
  @objc private func checkForUpdates() { updater?.checkForUpdates() }
  @objc private func quit() { NSApp.terminate(nil) }
  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await palette.finish()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

extension Configuration.Appearance {
  /// What `NSApp.appearance` takes: nil follows the system.
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}
