import AppKit
import SwiftUI
import WicketCore

/// A borderless, non-activating floating panel: it takes the keyboard without activating Wicket, so
/// the app the user came from stays frontmost and gets focus back when the palette closes.
final class PalettePanel: NSPanel {
    /// Handles the palette's chords. Each one is consumed, even when it does nothing at the moment,
    /// so none ever reaches a text field.
    var onChord: (PaletteChord) -> Void = { _ in }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // Appears on the current Space, including over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    /// Palette chords are matched here, before the focused field: the field editor binds some of them
    /// (⌃N, ⌃P), and SwiftUI's `onKeyPress` never sees those. Keys an input method is composing with
    /// stay with it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, (firstResponder as? NSTextView)?.hasMarkedText() != true,
            let chord = PaletteChord(
                keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
                modifiers: Shortcut.Modifiers(event.modifierFlags))
        {
            onChord(chord)
            return
        }
        super.sendEvent(event)
    }

    /// There is no menu bar to route standard editing shortcuts, so handle them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift] {
            let action: Selector? =
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "x": #selector(NSText.cut(_:))
                case "c": #selector(NSText.copy(_:))
                case "v": #selector(NSText.paste(_:))
                case "a": #selector(NSText.selectAll(_:))
                case "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
                default: nil
                }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the panel: summoning, placement, dismissal and activation. The content is all SwiftUI.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 680, height: 440)

    let model: PaletteModel
    private let actions: ActionRunner
    private let openSettings: () -> Void
    private let panel: PalettePanel
    /// Timestamp of the event that summoned the palette, until it is on screen.
    private var pendingShow: (eventTime: TimeInterval, showStart: TimeInterval)?

    init(model: PaletteModel, actions: ActionRunner, openSettings: @escaping () -> Void) {
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        panel = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size))
        super.init()
        panel.delegate = self
        panel.onChord = { [weak self] in self?.handle($0) }
        let root = NSHostingView(
            rootView: PaletteRootView(
                model: model, onRun: { [weak self] in self?.run($0, action: $1) },
                onHide: { [weak self] in self?.hide() }))
        // The controller owns the frame; SwiftUI must never resize the panel.
        root.sizingOptions = []
        panel.contentView = root
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: panel)
    }

    func toggle(eventTime: TimeInterval) {
        if panel.isVisible { hide() } else { show(eventTime: eventTime) }
    }

    func show(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pendingShow = (eventTime, ProcessInfo.processInfo.systemUptime)
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusToken += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Reset while hidden so the next summon has nothing to redraw.
        model.actionMenu = nil
        model.commandHeld = false
        model.query = ""
    }

    /// Runs the action at `position` in the item's actions (0 is the primary) and closes the palette.
    /// Does nothing if the item has no such action, so Return on a message row keeps the palette open.
    func run(_ item: Item?, action position: Int) {
        guard let item, item.actions.indices.contains(position) else { return }
        model.recordUse(of: item)
        hide()
        actions.run(item.actions[position])
    }

    /// The keyboard model's chords; plain keys are handled by the focused field's `onKeyPress`.
    private func handle(_ chord: PaletteChord) {
        switch chord {
        case .toggleActions:
            if model.actionMenu != nil {
                model.actionMenu = nil
            } else if let item = model.selectedItem, !item.actions.isEmpty {
                model.actionMenu = ActionMenu(item: item)
            }
        case .runSecondary:
            run(model.actionMenu?.item ?? model.selectedItem, action: 1)
        case .runRow(let row):
            guard model.actionMenu == nil, model.results.indices.contains(row) else { break }
            run(model.results[row], action: 0)
        case .openSettings:
            hide()
            openSettings()
        case .move(let delta):
            if model.actionMenu != nil {
                model.actionMenu?.moveSelection(by: delta)
            } else {
                model.moveSelection(by: delta)
            }
        }
    }

    /// Horizontally centred on the screen with the pointer, a fifth of the way down.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: (visible.midX - Self.size.width / 2).rounded(),
            y: (visible.maxY - visible.height * 0.2 - Self.size.height).rounded())
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }

    // MARK: Measurement

    @objc private func occlusionChanged() {
        guard panel.occlusionState.contains(.visible), let pending = pendingShow else { return }
        pendingShow = nil
        let now = ProcessInfo.processInfo.systemUptime
        Perf.log(
            String(
                format: "hotkey→visible %.2f ms (event→show %.2f ms, show→visible %.2f ms)",
                (now - pending.eventTime) * 1000, (pending.showStart - pending.eventTime) * 1000,
                (now - pending.showStart) * 1000))
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
