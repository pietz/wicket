import Foundation
import WicketCore

/// Where Wicket's own files live: extensions, their data and the host-owned stores, in the edition's
/// Application Support folder, `Wicket` (shown below) or `Wicket Dev` (`Edition`).
public enum ExtensionPaths {
    /// `~/Library/Application Support/Wicket/Extensions`: one folder per extension, named by its id.
    public static var extensions: URL { support.appending(path: "Extensions", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Wicket/Revisions`: the sealed revisions (`RevisionStore`).
    public static var revisions: URL { support.appending(path: "Revisions", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Wicket/approvals.json`: the approved revision of each
    /// extension (`Approvals`), written only by Wicket's UI.
    public static var approvals: URL { support.appending(path: "approvals.json") }

    /// `~/Library/Application Support/Wicket/agent-permissions.json`: the permission level chosen for
    /// each agent (`AgentPermissions`), written only by Settings ▸ AI.
    public static var agentPermissions: URL { support.appending(path: "agent-permissions.json") }

    /// `~/Library/Application Support/Wicket/uv`: uv's cache and Pythons for uv extensions
    /// (`UVStorage`), Wicket's own rather than the user's.
    public static var uv: URL { support.appending(path: "uv", directoryHint: .isDirectory) }

    /// An extension's `WICKET_DATA_DIR`. Outside its folder, so it survives updates.
    public static func data(for id: String) -> URL {
        support.appending(path: "ExtensionData/\(id)", directoryHint: .isDirectory)
    }

    private static var support: URL { Edition.current.supportDirectory }
}
