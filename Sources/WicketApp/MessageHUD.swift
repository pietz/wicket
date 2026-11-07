import AppKit
import SwiftUI
import WicketCore

extension Message.Kind {
    /// What leads a message, in the HUD and the footer alike, so the outcome lands before the
    /// sentence is read.
    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// A message (`Messages`) while the card isn't up, such as a command that closed the palette ("Dark
/// mode on"): a small glass capsule where the pill was, its kind's symbol leading, gone after two
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

    /// Shows `message` centred on `center`.
    func show(_ message: Message, centeredAt center: NSPoint) {
        let content = NSHostingView(rootView: HUDView(message: message))
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
    let message: Message

    var body: some View {
        Label(message.text, systemImage: message.kind.symbol)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            // Room for the glass rim and its shadow, as in the palette.
            .padding(20)
    }
}
