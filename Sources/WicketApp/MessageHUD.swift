import AppKit
import SwiftUI

/// A message from a command that closed the palette ("Dark mode on"): a small glass capsule where
/// the pill was, a checkmark leading so the outcome lands before the sentence is read, gone after two
/// seconds (reading time). A newer message replaces it. It never takes the keyboard or the mouse.
@MainActor
final class MessageHUD {
    static let duration = Duration.seconds(2)
    private let panel: NSPanel
    private var dismissal: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
    }

    /// Shows `message` centred on `center`, after `symbol` (a checkmark unless the outcome is
    /// something else, such as a paste that only copied).
    func show(_ message: String, symbol: String = "checkmark.circle.fill", centeredAt center: NSPoint) {
        let content = NSHostingView(rootView: HUDView(message: message, symbol: symbol))
        let size = content.fittingSize
        panel.contentView = content
        panel.setFrame(
            NSRect(
                x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                width: size.width, height: size.height),
            display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        dismissal?.cancel()
        dismissal = Task { [panel] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }
            // A newer message took the panel during the fade.
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct HUDView: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            // Room for the glass rim and its shadow, as in the palette.
            .padding(20)
    }
}
