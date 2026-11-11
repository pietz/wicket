import AppKit
import SwiftUI

/// Focus and event routing extracted from the first Wicket, without its command/frame layer.
class PalettePanel: NSPanel {
  var beforeAction: (PaletteKeyAction) -> Bool = { _ in false }
  var onAction: (PaletteKeyAction) -> Void = { _ in }
  weak var input: NSTextField?
  var permissionPending: () -> Bool = { false }
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
    let flags: [(NSEvent.ModifierFlags, Shortcut.Modifiers)] = [
      (.command, .command), (.control, .control), (.option, .option), (.shift, .shift),
    ]
    let modifiers = flags.reduce(into: Shortcut.Modifiers()) { result, pair in
      if event.modifierFlags.contains(pair.0) { result.insert(pair.1) }
    }
    let action = PaletteKeyAction.decide(
      keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
      modifiers: modifiers, hasMarkedText: (firstResponder as? NSTextView)?.hasMarkedText() == true,
      permissionPending: permissionPending(), isARepeat: event.isARepeat)
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
    renderer = AnswerRenderer(folder: model.agent.folder) { NSWorkspace.shared.open($0) }
    super.init()
    panel.delegate = self
    panel.setAccessibilityLabel("Wicket Launcher")
    let root = NSHostingView(
      rootView: LauncherView(
        model: model, renderer: renderer,
        registerInput: { [weak self] field in self?.panel.input = field },
        run: { [weak self] action in self?.run(action) }, flatSurfaces: flatSurfaces))
    root.sizingOptions = []
    panel.contentView = root
    panel.permissionPending = { [weak model] in model.map { !$0.agent.permissions.isEmpty } ?? false }
    panel.beforeAction = { [weak model] action in model?.keyPressed(action) ?? false }
    panel.onAction = { [weak self] action in
      guard let self else { return }
      switch action {
      case .dismiss: if !model.escape() { hide() }
      case .run: run()
      case .ask: model.ask()
      case .permission(let allow): model.agent.decide(allow)
      case .move(let delta): model.move(delta)
      default: break
      }
    }
    model.onResultsChange = { [weak self] in
      guard let self else { return }
      if isOpen { renderContent() }
      resize()
    }
    model.onVoicePermissionFinished = { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.panel.makeKey()
    }
    renderer.onHeight = { [weak self] in self?.resize() }
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
    model.refresh()
  }
  func hide() {
    isOpen = false
    model.stopVoice()
    panel.orderOut(nil)
    model.dismiss()
    renderer.closed()
  }
  private func resize() {
    guard panel.isVisible || anchor != .zero else { return }
    let height = PaletteLayout.panelHeight(card: model.cardHeight(answer: renderer.height, cap: renderer.cap))
    let frame = PaletteLayout.frame(anchor: anchor, height: height)
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.invalidateShadow()
  }
  /// The screen that is open: the conversation if there is one, otherwise an extension's body.
  private func renderContent() {
    renderer.textSize = model.configuration.textSize
    renderer.capped = model.results.isEmpty
    if model.agent.active {
      renderer.update(
        model.agent.view.body ?? "", turn: model.agent.turnID,
        streaming: model.agent.busy && model.agent.streaming)
    } else if let body = model.body {
      renderer.update(body, turn: model.command?.turn ?? "", streaming: false)
    }
  }
  func run(_ chosen: RowAction? = nil) {
    model.stopVoice()
    if chosen == nil, model.returnAsks {
      model.ask()
      return
    }
    if chosen == nil, model.enterSelected() { return }
    guard !opening, let result = model.selected, let action = chosen ?? result.row.actions.first else {
      return
    }
    let input = model.input
    switch action {
    case .copy(let text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      model.record(result)
      hide()
    case .agent(let text): model.fill(text)
    case .run(let arguments): model.rerun(result.provider, arguments: arguments)
    case .paste(let text):
      guard AXIsProcessTrusted(), let previousApp, previousApp.processIdentifier != getpid(),
        !previousApp.isTerminated
      else {
        model.actionProblem =
          "Paste requires Accessibility access for Wicket and a previous app. Enable it in System Settings, then reopen Wicket."
        return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(OpenPolicy.paste(text), forType: .string)
      model.record(result)
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
      guard OpenPolicy.allowed(url) else {
        model.actionProblem = "This file cannot be opened by an extension action"
        return
      }
      if !url.isFileURL || url.pathExtension.lowercased() != "app" {
        if NSWorkspace.shared.open(url) {
          model.record(result)
          hide()
        } else {
          model.actionProblem = "Could not open \(url.absoluteString)"
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
            self.model.actionProblem = error.localizedDescription
          } else {
            self.model.record(result, input: input)
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
