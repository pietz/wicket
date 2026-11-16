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
  private var settings: SettingsWindowController!
  private var status: NSStatusItem!
  private var shortcutItem: NSMenuItem!
  private var updater: Updater?

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let directory = Edition.current.configDirectory()
    let history = UsageHistory(url: directory.appending(path: "usage.json"))
    let apps = AppsProvider()
    let clipboard = ClipboardHistory(
      url: Edition.current.privateDirectory().appending(path: "clipboard-history.json"))
    let runs = AgentHistory(url: Edition.current.privateDirectory().appending(path: "agent-history.json"))
    let model = LauncherModel(
      apps: apps, files: FilesProvider(), clipboard: clipboard, agentHistory: runs,
      history: history, folder: directory)
    do {
      try AnswerRenderer.installFiles(in: directory)
      try ExtensionHost.installFiles(in: directory)
    } catch {
      model.installProblem = error.localizedDescription
    }
    palette = PaletteController(model: model)
    apps.onChange = { [weak model] in model?.sourcesChanged([apps.id]) }
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let name = Edition.current.name
    updater = Updater()
    status.button?.image = NSImage(
      systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: name)
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
    configuration = model.store
    configuration.applyHotkey = { [weak self] in self?.hotkey.apply($0) }
    configuration.applyBinding = { [weak self] keys, target in
      guard let self else { return nil }
      return bindings.set(keys, for: target, launcher: hotkey.inEffect)
    }
    bindings.onPress = { [weak self] in self?.palette.press($0) }
    let register: (Configuration) -> Void = { [weak self] config in
      guard let self else { return }
      configuration.hotkeyProblem = hotkey.apply(config.hotkey)
      configuration.bindingProblem = bindings.apply(config.hotkeys, launcher: hotkey.inEffect)
    }
    // Either recorder, Settings' or the panel's Set Hotkey…, pauses every hotkey, so it hears the keys.
    let pause: (Bool) -> Void = { [weak self] paused in
      guard let self else { return }
      hotkey.pause(paused)
      bindings.pause(paused)
      if !paused { register(configuration.configuration) }
    }
    model.pauseHotkeys = pause
    settings = SettingsWindowController(
      store: configuration, extensions: model.extensions, clipboard: clipboard, runs: runs, updater: updater,
      pauseHotkey: pause)
    model.onSettings = { [weak self] in self?.showSettings() }
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
    var applied = Configuration()
    model.onConfigurationChange = { [weak self] config, _ in
      guard let self else { return }
      if let config, config != applied || hotkey.inEffect == nil {
        applied = config
        register(config)
        shortcutItem.title = "Open \(name) (\(hotkey.inEffect?.symbols ?? "menu"))"
      }
      status.button?.toolTip =
        model.problem ?? "\(name): \(hotkey.inEffect?.symbols ?? "use menu to open")"
    }
    configuration.start()
    model.extensions.start()
    Task { await apps.start() }
    palette.showOnLaunch(NSAppleEventManager.shared().currentAppleEvent)
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    palette.show()
    return true
  }

  public func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { palette.open(url) }
  }

  @objc private func show() { palette.show() }
  @objc private func showSettings() {
    palette.hide()
    settings.show()
  }
  @objc private func openConfigFolder() {
    NSWorkspace.shared.open(configuration.url.deletingLastPathComponent())
  }
  @objc private func checkForUpdates() { updater?.checkForUpdates() }
  @objc private func quit() { NSApp.terminate(nil) }
  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await palette.model.finish()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
