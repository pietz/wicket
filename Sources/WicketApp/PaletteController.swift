import AppKit
import SwiftUI
import WicketCore

/// A borderless, non-activating floating panel: it takes the keyboard without activating Wicket, so
/// the app the user came from stays frontmost and gets focus back when the palette closes.
final class PalettePanel: NSPanel {
    /// Handles the palette's chords. Each one is consumed, even when it does nothing at the moment,
    /// so none ever reaches a text field.
    var onChord: (PaletteChord) -> Void = { _ in }
    /// Sees every key press first; true consumes it. Voice input stops on any key here.
    var onKeyDown: (NSEvent) -> Bool = { _ in false }

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
    /// (⌃N, ⌃P), and SwiftUI's `onKeyPress` never sees those. ⌘ chords usually arrive in
    /// `performKeyEquivalent` first, which AppKit calls before this.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown(event) { return }
        if event.type == .keyDown, let chord = chord(for: event) {
            onChord(chord)
            return
        }
        // A new frame rebuilds the search field and focuses it a run-loop turn later; a key that
        // lands in between (Escape, the first typed letter) would find no field. Focus it now.
        if event.type == .keyDown, !(firstResponder is NSTextView),
            let field = contentView?.firstEditableField
        {
            makeFirstResponder(field)
        }
        super.sendEvent(event)
    }

    /// AppKit offers a ⌘ key to the key window here, then to the main menu, and only then to
    /// `sendEvent`. So the palette's chords are claimed here (the menu binds ⌘, too), editing
    /// shortcuts go straight to the focused field, and any other key the main menu binds (⌘Q, ⌘W,
    /// ⌘H, ⌘M) is swallowed: the menu is for the settings window and never acts from the palette.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown(event) { return true }
        if let chord = chord(for: event) {
            onChord(chord)
            return true
        }
        if let edit = EditCommand(
            characters: event.charactersIgnoringModifiers, modifiers: Shortcut.Modifiers(event.modifierFlags)),
            NSApp.sendAction(edit.selector, to: nil, from: self)
        {
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.bindsKeyEquivalent(of: event) == true
    }

    /// The chord `event` is, unless an input method is composing with it.
    private func chord(for event: NSEvent) -> PaletteChord? {
        guard (firstResponder as? NSTextView)?.hasMarkedText() != true else { return nil }
        return PaletteChord(
            keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
            modifiers: Shortcut.Modifiers(event.modifierFlags))
    }
}

extension EditCommand {
    fileprivate var selector: Selector {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        }
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
    private let dispatcher: ActionDispatcher
    private let panel: PalettePanel
    /// The window's top-left corner, resolved once per summon so only the height ever changes.
    private var anchor = NSPoint.zero
    private var pendingShrink: Task<Void, Never>?
    /// The frame the card last followed, so a push or pop resizes at once.
    private var shownFrame: Frame.ID?
    /// Timestamp of the event that summoned the palette, until it is on screen.
    private var pendingShow: (eventTime: TimeInterval, showStart: TimeInterval)?
    /// The app that was frontmost when the palette was summoned, where `paste` types.
    private var previousApp: RunningApp?
    /// Where a message shows while the card is not up.
    private let hud = MessageHUD()
    /// Shows the palette once a command a hotkey ran (while it was hidden) has something to show.
    private var pendingReveal: Task<Void, Never>?

    init(model: PaletteModel, dispatcher: ActionDispatcher) {
        self.model = model
        self.dispatcher = dispatcher
        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: PaletteMetrics.windowSize(width: width, cardHeight: 0)))
        super.init()
        panel.delegate = self
        panel.onChord = { [weak self] in self?.handle($0) }
        panel.onKeyDown = { [weak self] in self?.keyDown($0) ?? false }
        model.session.onClose = { [weak self] in self?.hide() }
        model.session.messages.present = { [weak self] in self?.present($0) }
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
                    height: PaletteMetrics.cardHeight(
                        for: model.top, actionMenu: model.actionMenu, detailHeight: model.detailHeight),
                    frame: model.top.id, isCompact: model.top.isCompact,
                    isUnmeasuredDetail: model.top.isMeasured && model.detailHeight == nil)
            }
            for await card in cards {
                self?.follow(card)
            }
        }
    }

    func toggle(eventTime: TimeInterval) {
        if panel.isVisible { hide() } else { show(eventTime: eventTime) }
    }

    /// A summon: shows the palette, then captures where the user came from.
    func show(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        present(eventTime: eventTime)
        // After ordering front, so it stays off the hotkey-to-visible path. The panel doesn't
        // activate Wicket, so the frontmost app is still the one the user came from.
        capturePreviousApp()
        // Likewise after: the microphone and the analyzer start off the main actor.
        if let voice = model.voice, voice.listensOnOpen { voice.listen() }
    }

    private func present(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pendingShow = (eventTime, ProcessInfo.processInfo.systemUptime)
        anchor = Self.anchor(width: width)
        resize(cardHeight: 0)
        // ⌘ may have been pressed or released while hidden, where the view saw no change.
        model.commandHeld = NSEvent.modifierFlags.contains(.command)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusToken += 1
    }

    /// The app the user came from, where a paste types, and what they had selected there (the
    /// session's context, captured off the main actor).
    private func capturePreviousApp() {
        previousApp = Self.frontmostApp()
        model.pasteTarget = previousApp?.name
        model.session.captureContext(ContextCapture.start(from: previousApp))
    }

    /// The frontmost app, unless it is Wicket.
    private static func frontmostApp() -> RunningApp? {
        NSWorkspace.shared.frontmostApplication.flatMap {
            $0 == .current
                ? nil
                : RunningApp(
                    processID: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.voice?.stop()
        // Reset while hidden so the next summon has nothing to redraw. Resetting the session also
        // cancels every command run, including one an action is still opening.
        pendingShrink?.cancel()
        pendingReveal?.cancel()
        model.actionMenu = nil
        model.showToast(nil)
        model.commandHeld = false
        model.session.reset()
        model.session.captureContext(nil)
        model.cardHeight = 0
    }

    // MARK: Bound commands

    /// Runs a command bound to a global hotkey (settings.json `commands`) without the root search
    /// first, through the same dispatcher as its row. One that shows something summons the palette
    /// straight into its frame (a command that takes typed text, like Ask AI, into its frame waiting
    /// for the text); one that just does something (Quit, a toggle answering `close`) shows nothing
    /// but its close message, since a hidden palette is revealed only when the command has content
    /// (or is still running after `revealDelay`). Pressing a command's hotkey while its frame is on
    /// top closes the palette, as the palette's own hotkey does.
    func run(bound id: CommandID) {
        if panel.isVisible, case .screen(let frame) = model.top.content, frame.run?.command.id == id {
            hide()
            return
        }
        // Start Listening's hotkey while listening stops it and keeps what was said, rather than
        // resetting the palette first like any other command's hotkey.
        if id == .listen, let voice = model.voice, voice.isListening {
            voice.stop()
            return
        }
        pendingReveal?.cancel()
        if panel.isVisible {
            model.actionMenu = nil
            model.session.reset()
        } else {
            capturePreviousApp()
        }
        switch dispatcher.perform(.run(command: id), in: ActionContext(previousApp: previousApp)) {
        case .close: hide()
        case .push(let detail):
            model.session.push(detail)
            reveal()
        case .open(let run):
            model.session.open(run)
            if model.session.opening == nil { reveal() } else if !panel.isVisible { revealWhenOpened() }
        }
    }

    /// How long a command a hotkey ran may work unseen before the palette shows it running.
    private static let revealDelay = Duration.milliseconds(250)

    /// Shows the palette, sized for the frame already on top: the card follows the top frame only
    /// while the panel is visible. `run(bound:)` captured where the user came from already.
    private func reveal() {
        guard !panel.isVisible else { return }
        present()
        if let height = PaletteMetrics.cardHeight(
            for: model.top, actionMenu: nil, detailHeight: model.detailHeight)
        {
            setCardHeight(height)
        }
    }

    /// Reveals the palette when the command being opened pushes its frame, or after `revealDelay`
    /// if it is still running; not if it closed or reloaded without one.
    private func revealWhenOpened() {
        let session = model.session
        pendingReveal = Task { [weak self] in
            let delay = Task {
                try? await Task.sleep(for: Self.revealDelay)
                guard !Task.isCancelled, session.opening != nil else { return }
                self?.reveal()
            }
            defer { delay.cancel() }
            for await (opening, pushed) in Observations({ (session.opening != nil, session.frames.count > 1) }
            ) {
                guard !Task.isCancelled else { return }
                if pushed { self?.reveal() }
                if pushed || !opening { return }
            }
        }
    }

    /// Escape in the search field: clears the text, else goes back a frame, else hides.
    func escape() {
        if model.session.escape() == .hide { hide() }
    }

    /// Runs the action at `position` in the target's actions (0 is the primary) and applies its
    /// outcome. Does nothing if there is no such action, so Return on a message row keeps the
    /// palette open, or while an action is still opening a command (one at a time).
    func run(_ target: ActionTarget?, action position: Int) {
        guard model.session.opening == nil, let target, target.actions.indices.contains(position) else {
            return
        }
        if let item = target.item { model.recordUse(of: item) }
        perform(target.actions[position])
    }

    private func perform(_ action: Item.Action) {
        guard model.session.opening == nil else { return }
        model.actionMenu = nil
        model.voice?.stop()
        switch dispatcher.perform(action, in: ActionContext(previousApp: previousApp)) {
        case .close: hide()
        case .push(let detail): model.session.push(detail)
        case .open(let run): model.session.open(run)
        }
    }

    // MARK: Voice

    /// Start Listening (its row or hotkey): shows the palette if a hotkey ran it while hidden
    /// (`run(bound:)` captured where the user came from already), then listens, or says how to
    /// turn voice on.
    func listen() {
        if !panel.isVisible { present() }
        guard let voice = model.voice else { return }
        voice.toggle()
        // From its row, the field still says "listen"; the words replace it.
        if voice.isListening { model.session.setSpokenQuery("") }
    }

    /// While listening, any key stops it (`VoiceInput.keyPressed`).
    private func keyDown(_ event: NSEvent) -> Bool {
        model.voice?.keyPressed(isEscape: event.keyCode == Self.escapeKeyCode) ?? false
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Every message (`Messages`) shows here: in the footer while the card is up, else in the HUD
    /// where the pill is or was (a command that closed the palette, a paste that only copied).
    private func present(_ message: Message) {
        if panel.isVisible, model.isExpanded {
            model.showToast(message)
            return
        }
        let pill = NSPoint(
            x: anchor.x + PaletteMetrics.margin + width / 2,
            y: anchor.y - PaletteMetrics.margin - PaletteMetrics.pillHeight / 2)
        hud.show(message, centeredAt: pill)
    }

    /// The keyboard model's chords; plain keys are handled by the focused field's `onKeyPress`.
    private func handle(_ chord: PaletteChord) {
        switch chord {
        case .toggleActions:
            if model.actionMenu != nil {
                model.actionMenu = nil
            } else if let target = model.target, !target.actions.isEmpty {
                model.actionMenu = ActionMenu(target: target, pasteTarget: model.pasteTarget)
            }
        case .runSecondary:
            run(model.actionMenu?.target ?? model.target, action: 1)
        case .runRow(let row):
            guard model.actionMenu == nil, model.results.indices.contains(row) else { break }
            run(ActionTarget(item: model.results[row]), action: 0)
        case .openSettings:
            perform(.run(command: .settings))
        case .move(let delta):
            if model.actionMenu != nil {
                model.actionMenu?.moveSelection(by: delta)
            } else {
                model.moveSelection(by: delta)
            }
        }
    }

    // MARK: Frame

    /// The card the top frame wants: its height (nil to keep the current one), and what decides how
    /// fast to get there.
    private struct Card {
        let height: CGFloat?
        let frame: Frame.ID
        let isCompact: Bool
        /// A detail not laid out yet, so not measured; it needs a card to be laid out in.
        let isUnmeasuredDetail: Bool
    }

    /// Grows at once; shrinks after `shrinkDelay` without a taller result, so results that drop and
    /// return within it never move the card. Clearing the query (back to the bare pill) and going
    /// to another frame change it at once; a command frame still waiting for its first content, or a
    /// detail for its first measurement, keeps the card as it is, and the content then sizes it at
    /// once. A detail with no card to keep opens a small one to be measured in, then grows to fit.
    /// So a streaming answer's card grows with the text (it never shrinks mid-stream, see
    /// `DetailMeasure`), and its scroll position holds once the card is at its tallest.
    private func follow(_ card: Card) {
        pendingShrink?.cancel()
        let unmeasured = card.isUnmeasuredDetail && model.cardHeight == 0
        guard let height = card.height ?? (unmeasured ? PaletteMetrics.unmeasuredDetailHeight : nil) else {
            return
        }
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

extension NSView {
    /// The first editable text field in this view's subtree, depth first: the palette's search field.
    fileprivate var firstEditableField: NSTextField? {
        for subview in subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let field = subview.firstEditableField { return field }
        }
        return nil
    }
}
