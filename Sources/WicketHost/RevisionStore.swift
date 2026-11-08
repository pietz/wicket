import Darwin
import Foundation
import WicketCore

/// One retained, read-only copy of an extension: the exact bytes its revision was hashed from, and
/// its manifest as read from them. Only `RevisionStore` makes one, so a value of this type always
/// names a folder the host sealed: what is checked and what runs is this folder, never the live
/// authoring folder an agent may still be writing.
public struct SealedRevision: Sendable, Hashable {
    public let revision: ExtensionRevision
    /// `<store>/<id>/<sha256>`, read-only.
    public let folder: URL
    public let manifest: Manifest

    fileprivate init(revision: ExtensionRevision, folder: URL, manifest: Manifest) {
        self.revision = revision
        self.folder = folder
        self.manifest = manifest
    }
}

/// Why a folder could not be sealed.
public enum SealError: Error, Sendable, Equatable, CustomStringConvertible {
    case revision(RevisionError)
    case manifest(ManifestError)
    /// The manifest's id isn't the one the folder was sealed as.
    case wrongID(expected: String, found: String)
    case storage(String)

    public var description: String {
        switch self {
        case .revision(let error): error.description
        case .manifest(let error): error.description
        case .wrongID(_, let found): "the folder must be named after the id \(found)"
        case .storage(let message): "could not seal the folder: \(message)"
        }
    }
}

/// Host-managed storage of sealed revisions: `<root>/<extension id>/<sha256>/`, each a read-only
/// copy whose hash is its name. Sealing copies the folder, takes write permission away, and hashes
/// the copy, so a revision identifies exactly the bytes kept, even if the authoring folder changed
/// while it was copied. Synchronous file work: call it off the main actor.
public struct RevisionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// A store in a fresh temporary folder, for `wicket check`; `removeAll` deletes it.
    public static func temporary() -> RevisionStore {
        RevisionStore(
            root: FileManager.default.temporaryDirectory.appending(
                path: "wicket-revisions-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// Seals `folder` as the extension `id` (nil: the id its manifest gives), returning the retained
    /// revision. A folder whose revision is retained already isn't copied again (its hash is
    /// computed from the folder, then the retained copy is used). Throws if the folder has no
    /// revision (`RevisionError`), no valid manifest, or a manifest for another id.
    public func seal(_ folder: URL, id: String? = nil) throws(SealError) -> SealedRevision {
        let tree: RevisionTree
        do {
            tree = try RevisionTree(folder)
        } catch {
            throw .revision(error)
        }
        // The manifest first: a folder that isn't an extension leaves nothing behind.
        let manifest: Manifest
        do {
            manifest = try Manifest.load(from: folder)
        } catch {
            throw .manifest(error)
        }
        let id = id ?? manifest.id
        guard Manifest.isSlug(id) else { throw .wrongID(expected: id, found: manifest.id) }
        guard manifest.id == id else { throw .wrongID(expected: id, found: manifest.id) }
        let current: ExtensionRevision
        do {
            current = try tree.revision(id: id)
        } catch {
            throw .revision(error)
        }
        if let retained = retained(current) { return retained }

        let parent = root.appending(path: id, directoryHint: .isDirectory)
        let staging = parent.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw .storage(error.localizedDescription)
        }
        do {
            try tree.copy(to: staging)
            // The copy's own hash: what is kept is what the revision names.
            let revision = try RevisionTree(staging).revision(id: id)
            let manifest: Manifest
            do {
                manifest = try Manifest.load(from: staging)
            } catch {
                Self.remove(staging)
                throw SealError.manifest(error)
            }
            guard manifest.id == id else {
                Self.remove(staging)
                throw SealError.wrongID(expected: id, found: manifest.id)
            }
            let final = parent.appending(path: revision.sha256, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: final.path) {
                Self.remove(staging)
            } else if rename(staging.path, final.path) != 0 {
                Self.remove(staging)
                throw SealError.storage(String(cString: strerror(errno)))
            }
            return SealedRevision(revision: revision, folder: final, manifest: manifest)
        } catch let error as SealError {
            throw error
        } catch let error as RevisionError {
            Self.remove(staging)
            throw .revision(error)
        } catch {
            Self.remove(staging)
            throw .storage(error.localizedDescription)
        }
    }

    /// The retained copy of `revision`, if the store has it and its manifest loads. Its contents
    /// are trusted, not hashed again: the store is host-owned and read-only.
    public func retained(_ revision: ExtensionRevision) -> SealedRevision? {
        let folder = root.appending(
            path: "\(revision.extensionID)/\(revision.sha256)", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path),
            let manifest = try? Manifest.load(from: folder), manifest.id == revision.extensionID
        else { return nil }
        return SealedRevision(revision: revision, folder: folder, manifest: manifest)
    }

    /// Deletes every revision not in `keeping` (the caller names what it needs: the active, the
    /// discovered, those still running, and each extension's approved and previous approved one),
    /// every staging folder a crash left, and an extension's folder once it holds none.
    public func prune(keeping: Set<ExtensionRevision>) {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids where Manifest.isSlug(id) {
            let parent = root.appending(path: id, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names {
                let folder = parent.appending(path: name, directoryHint: .isDirectory)
                if name.hasPrefix(".staging-") {
                    Self.remove(folder)
                } else if !keeping.contains(ExtensionRevision(extensionID: id, sha256: name)) {
                    Self.remove(folder)
                }
            }
            // An extension with no revision left leaves no folder behind.
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    /// Deletes the whole store, for a temporary one.
    public func removeAll() {
        Self.remove(root)
    }

    /// Deletes a sealed (read-only) folder: write permission comes back to every folder first.
    static func remove(_ folder: URL) {
        if let walk = FileManager.default.enumerator(atPath: folder.path) {
            for case let path as String in walk {
                let url = folder.appending(path: path)
                var info = stat()
                if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, 0o755) }
            }
        }
        chmod(folder.path, 0o755)
        try? FileManager.default.removeItem(at: folder)
    }
}
