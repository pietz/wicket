import Foundation

/// Where extensions and their data live.
public enum ExtensionPaths {
    /// `~/Library/Application Support/Wicket/Extensions`: one folder per extension, named by its id.
    public static var extensions: URL { support.appending(path: "Extensions", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Wicket/Revisions`: the sealed revisions (`RevisionStore`).
    public static var revisions: URL { support.appending(path: "Revisions", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Wicket/Staging`: one folder per build job (`BuildJobs`), holding
    /// the folder its agent writes and the revision sealed from it.
    public static var staging: URL { support.appending(path: "Staging", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Wicket/approvals.json`: the approved revision of each
    /// extension (`Approvals`), written only by Wicket's UI.
    public static var approvals: URL { support.appending(path: "approvals.json") }

    /// An extension's `WICKET_DATA_DIR`. Outside its folder, so it survives updates.
    public static func data(for id: String) -> URL {
        support.appending(path: "ExtensionData/\(id)", directoryHint: .isDirectory)
    }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "Wicket")
    }
}
