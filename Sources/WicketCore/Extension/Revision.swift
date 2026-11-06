import Foundation

/// One exact version of an extension's folder: a SHA-256 over its files (WicketHost computes it,
/// with the rules in docs/architecture.md). Every item and detail an extension sends carries the
/// revision it came from on its `run` actions, so a run asked for by replaced code is refused, and
/// the consent store approves revisions, never names.
public struct ExtensionRevision: Hashable, Codable, Sendable {
    public var extensionID: String
    /// Lowercase hex.
    public var sha256: String

    public init(extensionID: String, sha256: String) {
        self.extensionID = extensionID
        self.sha256 = sha256
    }
}
