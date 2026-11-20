import AppKit
import SwiftUI

/// Where the panel's keys go once decided (`PaletteKeyAction.decide`), and what deciding them needs.
@MainActor protocol PaletteKeyTarget: AnyObject {
  var permissionPending: Bool { get }
  var hasArguments: Bool { get }
  /// Does what a key means; false leaves it to the panel: AppKit's editing shortcuts and the keys it types.
  func handle(_ action: PaletteKeyAction) -> Bool
}

/// Focus and event routing extracted from the first Wicket, without its command/frame layer.
class PalettePanel: NSPanel {
  weak var target: (any PaletteKeyTarget)?
  /// The input's native field, which the first key finds even before SwiftUI finished an update.
  weak var field: NSTextField?
  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    animationBehavior = .none
  }
  /// A borderless panel refuses key status by default; without it the launcher gets no typing,
  /// and clicking away never resigns key to close it.
  override var canBecomeKey: Bool { true }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, route(event) { return }
    super.sendEvent(event)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    route(event) || super.performKeyEquivalent(with: event)
  }
  func route(_ event: NSEvent) -> Bool {
    guard isKeyWindow else { return false }
    // The first key after summon must find the field even before SwiftUI finishes its update.
    let flagsOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let permissionPending = target?.permissionPending == true
    if !permissionPending, !(firstResponder is NSTextView), !(firstResponder is NSTextField),
      flagsOnly.isDisjoint(with: [.command, .control]),
      ![48, 53, 36, 76, 125, 126].contains(Int(event.keyCode)),
      let field
    {
      makeFirstResponder(field)
    }
    let action = PaletteKeyAction.decide(
      keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
      modifiers: Shortcut.Modifiers(event.modifierFlags),
      hasMarkedText: (firstResponder as? NSTextView)?.hasMarkedText() == true,
      permissionPending: permissionPending, isARepeat: event.isARepeat,
      hasArguments: target?.hasArguments == true)
    if target?.handle(action) == true { return true }
    switch action {
    case .passThrough: return false
    case .edit(let edit):
      let selector: Selector =
        switch edit {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        }
      NSApp.sendAction(selector, to: nil, from: self)
    default: break
    }
    return true
  }

}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate, PaletteKeyTarget, PaletteSurface {
  let panel: PalettePanel
  let model: LauncherModel
  let navigator: Navigator
  let renderer: AnswerRenderer
  /// What the panel types and says into the screens, and its voice.
  let input: PanelInput
  /// Records a row's hotkey: Set Hotkey… makes the next shortcut pressed its hotkey, under the
  /// launcher's rules, with every global hotkey paused (`pauseHotkeys`) so it hears the keys.
  let recorder = ShortcutRecorder()
  private let pauseHotkeys: (Bool) -> Void
  /// Where the Settings destination goes.
  private let settings: SettingsWindowController?
  private var anchor = NSPoint.zero
  private var opening = false
  private var previousApp: NSRunningApplication?
  private var visibleStarted: TimeInterval?
  /// Between `show` and `hide`. A hidden panel renders nothing, so the renderer can release its page.
  private var isOpen = false

  /// `flatSurfaces` draws solid surfaces instead of glass, which an offscreen render cannot show.
  init(
    model: LauncherModel, flatSurfaces: Bool = false, panel: PalettePanel = PalettePanel(),
    transcriber: @escaping () -> any Transcriber = { AppleTranscriber() },
    settings: SettingsWindowController? = nil, pauseHotkeys: @escaping (Bool) -> Void = { _ in }
  ) {
    self.panel = panel
    self.model = model
    self.settings = settings
    self.pauseHotkeys = pauseHotkeys
    let navigator = model.navigator
    self.navigator = navigator
    // A `wicket://` link in a page is an address; any other goes to the system.
    renderer = AnswerRenderer(folder: model.agent.folder) { [weak navigator] url in
      if let address = Address(url: url) { navigator?.go(address) } else { NSWorkspace.shared.open(url) }
    }
    input = PanelInput(
      navigator: navigator, agent: model.agent, store: model.store, folder: model.agent.folder,
      transcriber: transcriber,
      permissionFinished: { [weak panel] in
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
      })
    super.init()
    panel.delegate = self
    panel.target = self
    navigator.surface = self
    panel.setAccessibilityLabel("Wicket Launcher")
    let root = NSHostingView(
      rootView: LauncherView(
        model: model, input: input, recorder: recorder, renderer: renderer,
        registerInput: { [weak self] field in self?.panel.field = field },
        run: { [weak self] action in self?.run(action) }, flatSurfaces: flatSurfaces))
    root.sizingOptions = []
    panel.contentView = root
    renderer.onHeight = { [weak self] in self?.resize() }
    // A click on a page's target is Return on it, if it was made on the page shown now.
    renderer.onTarget = { [weak self] id, turn in
      guard let self, navigator.clickTarget(id, turn: turn) else { return }
      run()
    }
  }
  var permissionPending: Bool { !model.agent.permissions.isEmpty }
  var hasArguments: Bool { !navigator.declaredArguments.isEmpty }
  func handle(_ action: PaletteKeyAction) -> Bool {
    if input.keyPressed(action) { return true }
    switch action {
    case .dismiss: if !navigator.escape() { hide() }
    case .run: run()
    case .send: navigator.askAgent()
    case .actions: navigator.toggleActions()
    case .permission(let allow): model.agent.decide(allow)
    case .move(let delta): navigator.move(delta)
    case .focus(let delta): navigator.moveFocus(delta)
    case .edit, .consume, .passThrough: return false
    }
    return true
  }
  /// What the screens show changed: drawn in the same turn, so the native frame and the content change
  /// together. A hidden panel renders nothing.
  func present(_ change: PaletteChange) {
    switch change {
    case .content:
      input.screensChanged()
      if isOpen { renderContent() }
      resize()
    case .selection:
      renderer.selected = navigator.selectedTarget
      // Beside a list, the selected item's detail, with its neighbors' pictures prepared.
      if isOpen, navigator.splits {
        renderContent()
        PageIcons.prepare(navigator.nearbyPictures)
      }
    }
  }
  func prepare(_ page: Page, turn: String) async -> Bool {
    guard isOpen else { return true }
    renderer.textSize = model.configuration.textSize
    renderer.selected = nil
    await renderer.render(page, turn: turn)
    return renderer.renderedTurn == turn
  }
  func perform(_ effect: PaletteEffect) {
    switch effect {
    case .close: hide()
    case .settings: showSettings()
    case .run(let action, let result): perform(action, from: result)
    }
  }
  /// The native Settings window, which the launcher leaves for.
  func showSettings() {
    hide()
    settings?.show()
  }
  func toggle(eventTime: TimeInterval) {
    if panel.isVisible { hide() } else { show(eventTime: eventTime) }
  }
  func showOnLaunch(_ event: NSAppleEventDescriptor?, orderFront: Bool = true) {
    if event?.eventID == kAEOpenApplication,
      event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    {
      return
    }
    show(orderFront: orderFront, listen: false)
  }
  func show(
    eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime, orderFront: Bool = true,
    listen: Bool = true
  ) {
    guard !panel.isVisible else {
      panel.makeKey()
      return
    }
    previousApp = NSWorkspace.shared.frontmostApplication
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    anchor = NSPoint(
      x: (visible.midX - PaletteLayout.width / 2).rounded(),
      y: (visible.maxY - visible.height * 0.2 + PaletteLayout.margin).rounded())
    model.reopen()
    renderer.opened()
    renderer.cap = PaletteLayout.answerCap(available: anchor.y - visible.minY)
    isOpen = true
    renderContent()
    resize()
    visibleStarted = eventTime
    if orderFront {
      if panel.canBecomeKey { panel.makeKeyAndOrderFront(nil) }
      panel.orderFrontRegardless()
    }
    if listen { input.arm() }
    panel.contentView?.layoutSubtreeIfNeeded()
    if panel.canBecomeKey, let input = panel.field {
      panel.makeFirstResponder(input)
      (input.currentEditor() as? NSTextView)?.setSelectedRange(
        NSRange(location: input.stringValue.utf16.count, length: 0))
    }
    navigator.refresh()
  }
  func hide() {
    isOpen = false
    input.stop(.hidden)
    panel.orderOut(nil)
    recorder.stop()
    navigator.dismiss()
    renderer.closed()
  }
  private func resize() {
    guard panel.isVisible || anchor != .zero else { return }
    let height = PaletteLayout.panelHeight(
      card: navigator.cardHeight(answer: renderer.height, cap: renderer.cap))
    let frame = PaletteLayout.frame(anchor: anchor, height: height)
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.invalidateShadow()
  }
  /// The page that is open: a detail, the conversation's answer or an extension's body, or beside a list
  /// the selected item's detail. Another list has none, and the renderer is not touched.
  private func renderContent() {
    if let preview = navigator.preview {
      renderer.textSize = model.configuration.textSize
      renderer.selected = nil
      return renderer.update(preview.page, turn: preview.turn, streaming: false)
    }
    guard let page = navigator.page else { return }
    renderer.textSize = model.configuration.textSize
    renderer.selected = navigator.selectedTarget
    renderer.update(
      page, turn: navigator.pageTurn,
      streaming: model.agent.active && !navigator.inDetail && model.agent.busy && model.agent.streaming)
  }
  /// A `wicket://` URL from outside: the panel opens on its address, and the user presses Return.
  func open(_ url: URL) {
    guard let address = Address(url: url) else { return }
    show()
    navigator.follow(address)
  }
  /// A hotkey from `hotkeys` in config.json (`LauncherModel.press`). The panel shows only for a view or a
  /// failure, and never listens: the hotkey named where to go.
  func press(_ target: HotkeyTarget) {
    Task {
      await model.press(target, prepare: { _ = await self.prepare($0, turn: $1) }) { show(listen: false) }
    }
  }
  /// Whether Set Hotkey… is recording this row's hotkey.
  func recordsHotkey(of result: Result) -> Bool {
    recorder.target != nil && recorder.target == navigator.hotkeyTarget(of: result)
  }
  /// Return, a button or a menu item (`Navigator.run`): dictation stops first.
  func run(_ chosen: RowAction? = nil) {
    input.stop(.run)
    navigator.run(chosen)
  }
  /// What Return, a button or a menu item chose that leaves the screens: the effects on the panel and the
  /// system. Nothing while an application is opening.
  private func perform(_ action: RowAction, from result: Result?) {
    guard !opening else { return }
    let input = navigator.input
    func record() { if let result { navigator.record(result) } }
    switch action.kind {
    case .copy, .clip(_, paste: false):
      guard writePasteboard(action.kind) else { return }
      record()
      hide()
    case .hotkey(let target, record: true):
      recorder.record(target, in: panel, store: model.store, pausing: pauseHotkeys)
    case .run, .send, .detail, .hotkey: break
    case .reveal(let url):
      NSWorkspace.shared.activateFileViewerSelecting([url])
      record()
      hide()
    case .paste, .clip(_, paste: true):
      guard AXIsProcessTrusted(), let previousApp, previousApp.processIdentifier != getpid(),
        !previousApp.isTerminated
      else {
        navigator.actionProblem =
          "Paste requires Accessibility access for Wicket and a previous app. Enable it in System Settings, then reopen Wicket."
        return
      }
      // An extension's paste lost its newlines when it was decoded; the host's own, such as a clipboard
      // history entry, pastes exactly what was copied.
      guard writePasteboard(action.kind) else { return }
      record()
      hide()
      previousApp.activate()
      Task {
        try? await Task.sleep(for: .milliseconds(120))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp.processIdentifier
        else { return }
        for down in [true, false] {
          let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)
          event?.flags = .maskCommand
          event?.postToPid(previousApp.processIdentifier)
        }
      }
    case .open(let url):
      if !url.isFileURL || url.pathExtension.lowercased() != "app" {
        if NSWorkspace.shared.open(url) {
          record()
          hide()
        } else {
          navigator.actionProblem = "Could not open \(url.absoluteString)"
        }
        return
      }
      opening = true
      // Keep the error visible if Launch Services refuses the application.
      NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
        Task { @MainActor in
          guard let self else { return }
          self.opening = false
          if let error {
            self.navigator.actionProblem = error.localizedDescription
          } else {
            if let result { self.navigator.record(result, input: input) }
            self.hide()
          }
        }
      }
    }
  }
  /// Writes a copy or paste action's content: its text, or a kept image resolved from its ID now. False, with
  /// the reason shown, when the image is gone.
  func writePasteboard(_ kind: RowAction.Kind) -> Bool {
    switch kind {
    case .copy(let text), .paste(let text): Pasteboard.write(text)
    case .clip(let id, _):
      guard model.clipboard?.write(id) == true else {
        navigator.actionProblem = "This image is no longer in the clipboard history"
        return false
      }
    default: return false
    }
    return true
  }
  /// Quitting: the microphone closes, then the services stop.
  func finish() async {
    await input.finish()
    await model.finish()
  }
  func windowDidResignKey(_ notification: Notification) {
    // Only the system consent dialog may borrow focus while voice starts.
    if input.voice?.requestingPermission != true { hide() }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard panel.occlusionState.contains(.visible), let started = visibleStarted else { return }
    visibleStarted = nil
    NSLog(
      "Wicket hotkey to visible: %.2f ms", (ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
}

/// Every pasteboard write of Wicket's text: its copy and paste actions, and a report's Copy.
@MainActor enum Pasteboard {
  static func write(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
