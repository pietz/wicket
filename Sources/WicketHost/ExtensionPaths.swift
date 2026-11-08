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

    /// `~/Library/Application Support/Wicket/commands.md`: Wicket's commands, written for each
    /// run to read on demand (`ExtensionAuthoring`).
    public static var commandList: URL { support.appending(path: "commands.md") }

    /// `~/Library/Application Support/Wicket/ExtensionHistory`: each extension's recent runs and the
    /// agent conversation that last built it (`ExtensionHistory`), deleted with it on Move to Trash.
    public static var history: URL {
        support.appending(path: "ExtensionHistory", directoryHint: .isDirectory)
    }

    /// An extension's `WICKET_DATA_DIR`. Outside its folder, so it survives updates.
    public static func data(for id: String) -> URL {
        support.appending(path: "ExtensionData/\(id)", directoryHint: .isDirectory)
    }

    private static var support: URL { Edition.current.supportDirectory }
}
