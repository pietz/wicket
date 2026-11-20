import AppKit
import SwiftUI

/// Focus and event routing extracted from the first Wicket, without its command/frame layer.
class PalettePanel: NSPanel {
  var beforeAction: (PaletteKeyAction) -> Bool = { _ in false }
  var onAction: (PaletteKeyAction) -> Void = { _ in }
  weak var input: NSTextField?
  var permissionPending: () -> Bool = { false }
  var hasArguments: () -> Bool = { false }
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
    if !permissionPending(), !(firstResponder is NSTextView), !(firstResponder is NSTextField),
      flagsOnly.isDisjoint(with: [.command, .control]),
      ![48, 53, 36, 76, 125, 126].contains(Int(event.keyCode)),
      let input
    {
      makeFirstResponder(input)
    }
    let action = PaletteKeyAction.decide(
      keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
      modifiers: Shortcut.Modifiers(event.modifierFlags),
      hasMarkedText: (firstResponder as? NSTextView)?.hasMarkedText() == true,
      permissionPending: permissionPending(), isARepeat: event.isARepeat, hasArguments: hasArguments())
    if beforeAction(action) { return true }
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
    case .consume: break
    default: onAction(action)
    }
    return true
  }

}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
  let panel: PalettePanel
  let model: LauncherModel
  let navigator: Navigator
  let renderer: AnswerRenderer
  private var anchor = NSPoint.zero
  private var opening = false
  private var previousApp: NSRunningApplication?
  private var visibleStarted: TimeInterval?
  /// Between `show` and `hide`. A hidden panel renders nothing, so the renderer can release its page.
  private var isOpen = false

  /// `flatSurfaces` draws solid surfaces instead of glass, which an offscreen render cannot show.
  init(model: LauncherModel, flatSurfaces: Bool = false, panel: PalettePanel = PalettePanel()) {
    self.panel = panel
    self.model = model
    let navigator = model.navigator
    self.navigator = navigator
    // A `wicket://` link in a page is an address; any other goes to the system.
    renderer = AnswerRenderer(folder: model.agent.folder) { [weak navigator] url in
      if let address = Address(url: url) { navigator?.go(address) } else { NSWorkspace.shared.open(url) }
    }
    super.init()
    panel.delegate = self
    model.window = panel
    panel.setAccessibilityLabel("Wicket Launcher")
    let root = NSHostingView(
      rootView: LauncherView(
        model: model, renderer: renderer,
        registerInput: { [weak self] field in self?.panel.input = field },
        run: { [weak self] action in self?.run(action) }, flatSurfaces: flatSurfaces))
    root.sizingOptions = []
    panel.contentView = root
    panel.permissionPending = { [weak model] in model.map { !$0.agent.permissions.isEmpty } ?? false }
    panel.hasArguments = { [weak navigator] in navigator.map { !$0.declaredArguments.isEmpty } ?? false }
    panel.beforeAction = { [weak model] action in model?.keyPressed(action) ?? false }
    panel.onAction = { [weak self] action in
      guard let self else { return }
      switch action {
      case .dismiss: if !navigator.escape() { hide() }
      case .run: run()
      case .send: navigator.askAgent()
      case .actions: navigator.toggleActions()
      case .permission(let allow): model.agent.decide(allow)
      case .move(let delta): navigator.move(delta)
      case .focus(let delta): navigator.moveFocus(delta)
      default: break
      }
    }
    navigator.onResultsChange = { [weak self] in
      guard let self else { return }
      if isOpen { renderContent() }
      resize()
    }
    navigator.onClose = { [weak self] in self?.hide() }
    navigator.onReturnReady = { [weak self] in self?.run() }
    model.onVoicePermissionFinished = { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.panel.makeKey()
    }
    renderer.onHeight = { [weak self] in self?.resize() }
    // A click on a page's target is Return on it, if it was made on the page shown now.
    renderer.onTarget = { [weak self] id, turn in
      guard let self, navigator.clickTarget(id, turn: turn) else { return }
      run()
    }
    navigator.onSelectionChange = { [weak self] in
      guard let self else { return }
      renderer.selected = navigator.selectedTarget
      // Beside a list, the selected item's detail, with its neighbors' pictures prepared.
      if isOpen, navigator.splits {
        renderContent()
        PageIcons.prepare(navigator.nearbyPictures)
      }
    }
    navigator.preparePage = { [weak self] page, turn in
      guard let self, isOpen else { return }
      renderer.textSize = model.configuration.textSize
      renderer.selected = nil
      await renderer.render(page, turn: turn)
    }
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
    if listen { model.armVoice() }
    panel.contentView?.layoutSubtreeIfNeeded()
    if panel.canBecomeKey, let input = panel.input {
      panel.makeFirstResponder(input)
      (input.currentEditor() as? NSTextView)?.setSelectedRange(
        NSRange(location: input.stringValue.utf16.count, length: 0))
    }
    navigator.refresh()
  }
  func hide() {
    isOpen = false
    model.stopVoice(.hidden)
    panel.orderOut(nil)
    model.recorder.stop()
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
  /// A hotkey from `hotkeys` in config.json (`Navigator.press`). The panel shows only for a view or a
  /// failure, and never listens: the hotkey named where to go.
  func press(_ target: HotkeyTarget) {
    Task { await navigator.press(target) { show(listen: false) } }
  }
  /// Return, a button or a menu item. Moving between views goes through the model's dispatcher; what is
  /// left here are the effects on the system.
  func run(_ chosen: RowAction? = nil) {
    model.stopVoice(.run)
    if chosen == nil, navigator.returnWaits {
      navigator.returnQueued = true
      return
    }
    guard !opening, let (action, result) = navigator.pick(chosen) else { return }
    if model.activate(action, from: result) { return }
    let input = navigator.input
    func record() { if let result { navigator.record(result) } }
    switch action.kind {
    case .copy, .clip(_, paste: false):
      guard model.writePasteboard(action.kind) else { return }
      record()
      hide()
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
      guard model.writePasteboard(action.kind) else { return }
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
  func windowDidResignKey(_ notification: Notification) {
    // Only the system consent dialog may borrow focus while voice starts.
    if model.voice?.requestingPermission != true { hide() }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard panel.occlusionState.contains(.visible), let started = visibleStarted else { return }
    visibleStarted = nil
    NSLog(
      "Wicket hotkey to visible: %.2f ms", (ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
}
