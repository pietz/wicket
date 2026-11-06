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

/// Owns the panel: summoning, placement, dismissal and activation, and the window's frame. The
/// content is all SwiftUI.
///
/// The window is either compact (just the pill) or expanded (pill and results card), always with
/// its top edge at the anchor resolved on summon, so the pill never moves. Expanding grows the window
/// at once, then animates the card into the transparent space; collapsing animates the card away,
/// then shrinks the window. SwiftUI never resizes the panel, so the two never fight over the frame.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let motion = Animation.snappy(duration: 0.28)
    /// How long a query with no results keeps the card, so slow sources (files) answering a beat
    /// after each keystroke don't make it flicker.
    static let collapseDelay = Duration.milliseconds(300)

    let model: PaletteModel
    private let actions: ActionRunner
    private let openSettings: () -> Void
    private let panel: PalettePanel
    /// The window's top-left corner, resolved once per summon so only the height ever changes.
    private var anchor = NSPoint.zero
    private var pendingCollapse: Task<Void, Never>?
    /// Timestamp of the event that summoned the palette, until it is on screen.
    private var pendingShow: (eventTime: TimeInterval, showStart: TimeInterval)?

    init(model: PaletteModel, actions: ActionRunner, openSettings: @escaping () -> Void) {
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: PaletteMetrics.windowSize(expanded: false)))
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
        Task { [weak self, model] in
            for await hasResults in Observations({ !model.results.isEmpty }) {
                self?.follow(hasResults: hasResults)
            }
        }
    }

    func toggle(eventTime: TimeInterval) {
        if panel.isVisible { hide() } else { show(eventTime: eventTime) }
    }

    func show(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pendingShow = (eventTime, ProcessInfo.processInfo.systemUptime)
        anchor = Self.anchor()
        resize(expanded: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusToken += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Reset while hidden so the next summon has nothing to redraw.
        pendingCollapse?.cancel()
        model.actionMenu = nil
        model.commandHeld = false
        model.query = ""
        model.isExpanded = false
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

    // MARK: Frame

    /// Expands as soon as there are results; collapses at once when the query is cleared, and after
    /// `collapseDelay` when the query matches nothing.
    private func follow(hasResults: Bool) {
        pendingCollapse?.cancel()
        if hasResults || model.query.isEmpty {
            setExpanded(hasResults)
            return
        }
        pendingCollapse = Task { [weak self] in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled else { return }
            self?.setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard panel.isVisible, expanded != model.isExpanded else { return }
        if expanded { resize(expanded: true) }
        withAnimation(Self.motion) {
            model.isExpanded = expanded
        } completion: { [weak self] in
            guard let self, model.isExpanded == expanded else { return }
            if !expanded { resize(expanded: false) }
            // The window's shadow follows the drawn shapes only when asked to.
            panel.invalidateShadow()
        }
    }

    /// Sets the height for the state, keeping the top edge at the anchor, and lays the content out
    /// before anything is drawn, so a summon never flashes the expanded layout and the pill never
    /// shifts while the window grows.
    private func resize(expanded: Bool) {
        let size = PaletteMetrics.windowSize(expanded: expanded)
        panel.setFrame(
            NSRect(origin: NSPoint(x: anchor.x, y: anchor.y - size.height), size: size), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    /// Horizontally centred on the screen with the pointer, its top a fifth of the way down.
    private static func anchor() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        let width = PaletteMetrics.windowSize(expanded: false).width
        return NSPoint(
            x: (visible.midX - width / 2).rounded(), y: (visible.maxY - visible.height * 0.2).rounded())
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
