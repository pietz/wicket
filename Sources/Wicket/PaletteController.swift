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
        hasShadow = false
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
/// The window is the pill and, while there are results, a card sized to them, always with its top
/// edge at the anchor resolved on summon, so the pill and the card's top never move. A taller card
/// grows the window at once, then animates the card into the transparent space; a shorter one (or
/// none) animates the card first, then shrinks the window. SwiftUI never resizes the panel, so the
/// two never fight over the frame.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let motion = Animation.snappy(duration: 0.28)
    /// How long the card keeps its height before shrinking, so slow sources (files) answering a beat
    /// after each keystroke don't make it flicker.
    static let shrinkDelay = Duration.milliseconds(300)

    let model: PaletteModel
    /// The pill's width, from settings; applied on the next summon.
    var width = CGFloat(Settings.defaultPaletteWidth)
    private let actions: ActionRunner
    private let openSettings: () -> Void
    private let panel: PalettePanel
    /// The window's top-left corner, resolved once per summon so only the height ever changes.
    private var anchor = NSPoint.zero
    private var pendingShrink: Task<Void, Never>?
    /// The frame the card last followed, so a push or pop resizes at once.
    private var shownFrame: Frame.ID?
    /// Timestamp of the event that summoned the palette, until it is on screen.
    private var pendingShow: (eventTime: TimeInterval, showStart: TimeInterval)?

    init(model: PaletteModel, actions: ActionRunner, openSettings: @escaping () -> Void) {
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: PaletteMetrics.windowSize(width: width, cardHeight: 0)))
        super.init()
        panel.delegate = self
        panel.onChord = { [weak self] in self?.handle($0) }
        let root = NSHostingView(
            rootView: PaletteRootView(
                model: model, onRun: { [weak self] in self?.run($0, action: $1) },
                onEscape: { [weak self] in self?.escape() }))
        // The controller owns the frame; SwiftUI must never resize the panel.
        root.sizingOptions = []
        panel.contentView = root
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: panel)
        Task { [weak self, model] in
            let cards = Observations {
                Card(
                    height: PaletteMetrics.cardHeight(for: model.top, actionMenu: model.actionMenu),
                    frame: model.top.id, isCompact: model.top.isCompact)
            }
            for await card in cards {
                self?.follow(card)
            }
        }
    }

    func toggle(eventTime: TimeInterval) {
        if panel.isVisible { hide() } else { show(eventTime: eventTime) }
    }

    func show(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pendingShow = (eventTime, ProcessInfo.processInfo.systemUptime)
        anchor = Self.anchor(width: width)
        resize(cardHeight: 0)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusToken += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Reset while hidden so the next summon has nothing to redraw.
        pendingShrink?.cancel()
        model.actionMenu = nil
        model.commandHeld = false
        model.session.reset()
        model.cardHeight = 0
    }

    /// Escape in the search field: clears the text, else goes back a frame, else hides.
    func escape() {
        if model.session.escape() == .hide { hide() }
    }

    /// Runs the action at `position` in the target's actions (0 is the primary) and closes the
    /// palette, except for showing a detail, which pushes it. Does nothing if there is no such
    /// action, so Return on a message row keeps the palette open.
    ///
    /// The detail case is the one outcome known before running; the dispatcher (refactor step 4)
    /// replaces this with outcomes for every action.
    func run(_ target: ActionTarget?, action position: Int) {
        guard let target, target.actions.indices.contains(position) else { return }
        if let item = target.item { model.recordUse(of: item) }
        let action = target.actions[position]
        if case .detail(let detail) = action {
            model.actionMenu = nil
            model.session.push(detail)
            return
        }
        hide()
        actions.run(action)
    }

    /// The keyboard model's chords; plain keys are handled by the focused field's `onKeyPress`.
    private func handle(_ chord: PaletteChord) {
        switch chord {
        case .toggleActions:
            if model.actionMenu != nil {
                model.actionMenu = nil
            } else if let target = model.target, !target.actions.isEmpty {
                model.actionMenu = ActionMenu(target: target)
            }
        case .runSecondary:
            run(model.actionMenu?.target ?? model.target, action: 1)
        case .runRow(let row):
            guard model.actionMenu == nil, model.results.indices.contains(row) else { break }
            run(ActionTarget(item: model.results[row]), action: 0)
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

    /// The card the top frame wants: its height, and what decides how fast to get there.
    private struct Card {
        let height: CGFloat
        let frame: Frame.ID
        let isCompact: Bool
    }

    /// Grows at once; shrinks after `shrinkDelay` without a taller result, so results that drop and
    /// return within it never move the card. Clearing the query (back to the bare pill) and going
    /// to another frame change it at once.
    private func follow(_ card: Card) {
        pendingShrink?.cancel()
        let height = card.height
        defer { shownFrame = card.frame }
        if height >= model.cardHeight || card.isCompact || card.frame != shownFrame {
            setCardHeight(height)
            return
        }
        pendingShrink = Task { [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard !Task.isCancelled else { return }
            self?.setCardHeight(height)
        }
    }

    /// The window only grows before the animation and only shrinks after it, so it always holds the
    /// card in flight, even when one change interrupts another.
    private func setCardHeight(_ height: CGFloat) {
        guard panel.isVisible, height != model.cardHeight else { return }
        if PaletteMetrics.windowSize(width: width, cardHeight: height).height > panel.frame.height {
            resize(cardHeight: height)
        }
        withAnimation(Self.motion) {
            model.cardHeight = height
        } completion: { [weak self] in
            guard let self, model.cardHeight == height else { return }
            resize(cardHeight: height)
        }
    }

    /// Sets the window for a card of `cardHeight`, keeping the top edge at the anchor, and lays the
    /// content out before anything is drawn, so a summon never flashes the old layout and the pill
    /// never shifts while the window grows. The shadow follows the drawn shapes only when asked to.
    private func resize(cardHeight: CGFloat) {
        let size = PaletteMetrics.windowSize(width: width, cardHeight: cardHeight)
        panel.setFrame(
            NSRect(origin: NSPoint(x: anchor.x, y: anchor.y - size.height), size: size), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    /// Horizontally centred on the screen with the pointer, its top a fifth of the way down.
    private static func anchor(width: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        let window = PaletteMetrics.windowSize(width: width, cardHeight: 0)
        return NSPoint(
            x: (visible.midX - window.width / 2).rounded(),
            y: (visible.maxY - visible.height * 0.2 + PaletteMetrics.margin).rounded())
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
