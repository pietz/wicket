import Foundation

/// A short sentence for the user that comes and goes by itself: a command's `close` or `reload`
/// message, a paste that could only copy. Never query text or anything secret.
public struct Message: Sendable, Hashable {
    /// What the message reports, which picks its symbol.
    public enum Kind: Sendable, Hashable {
        /// Something was done ("Dark mode on").
        case done
        /// The text is on the clipboard, but wasn't pasted.
        case copied
    }

    public var text: String
    public var kind: Kind

    public init(_ text: String, kind: Kind = .done) {
        self.text = text
        self.kind = kind
    }
}

/// The one way a transient message reaches the user. Anyone posts (the palette session for its
/// commands, the paste effect, later voice and onboarding); the app's presenter (`PaletteController`)
/// decides where it shows: in the card's footer while the card is up, else in the HUD where the
/// pill is or was.
@MainActor
public final class Messages {
    /// Shows a message. Set once by the presenter; until then messages are dropped.
    public var present: (Message) -> Void = { _ in }

    public init() {}

    public func post(_ message: Message) {
        present(message)
    }
}
