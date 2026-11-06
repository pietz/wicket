import AppKit
import SwiftUI

/// A borderless, non-activating floating panel: it takes the keyboard without activating Wicket, so
/// the app the user came from stays frontmost and gets focus back when the palette closes.
final class PalettePanel: NSPanel {
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

    /// There is no menu bar to route standard editing shortcuts, so handle them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift] {
            let action: Selector? = switch event.charactersIgnoringModifiers?.lowercased() {
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

@MainActor
final class PaletteController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let size = NSSize(width: 680, height: 440)

    let model = PaletteModel()
    private let panel: PalettePanel
    private let searchField = NSTextField()
    /// Timestamp of the event that summoned the palette, until it is on screen.
    private var pendingShow: (eventTime: TimeInterval, showStart: TimeInterval)?

    override init() {
        panel = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size))
        super.init()
        panel.delegate = self
        buildContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: panel)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(eventTime: TimeInterval) {
        if panel.isVisible { hide() } else { show(eventTime: eventTime) }
    }

    func show(eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let showStart = ProcessInfo.processInfo.systemUptime
        pendingShow = (eventTime, showStart)
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Reset while hidden so the next summon has nothing to redraw.
        searchField.stringValue = ""
        model.setQuery("")
    }

    func activate(index: Int) {
        guard model.results.indices.contains(index) else { return }
        let item = model.results[index]
        model.recordUse(of: item)
        hide()
        switch item.action {
        case .openApp(let url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { Perf.logger.error("open \(url.path, privacy: .public): \(error)") }
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: Layout

    private func buildContent() {
        // Liquid Glass costs ~12 ms per summon over NSVisualEffectView (measured, see CONCEPT.md).
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        // Untinted glass is hard to read over busy windows.
        glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)

        let container = NSView()
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .regular)
        searchField.placeholderString = "Search apps…"
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.delegate = self

        let separator = NSBox()
        separator.boxType = .separator

        let results = NSHostingView(
            rootView: ResultsView(model: model, onActivate: { [weak self] in self?.activate(index: $0) }))
        // The controller owns the frame; SwiftUI must never resize the panel.
        results.sizingOptions = []

        for view in [searchField, separator, results] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            results.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            results.topAnchor.constraint(equalTo: separator.bottomAnchor),
            results.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        glass.contentView = container
        panel.contentView = glass
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
        Perf.log(String(
            format: "hotkey→visible %.2f ms (event→show %.2f ms, show→visible %.2f ms)",
            (now - pending.eventTime) * 1000, (pending.showStart - pending.eventTime) * 1000,
            (now - pending.showStart) * 1000))
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)): activate(index: model.selection)
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                hide()
            } else {
                searchField.stringValue = ""
                model.setQuery("")
            }
        default: return false
        }
        return true
    }
}
