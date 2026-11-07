import CryptoKit
import Darwin
import Foundation
import WicketCore

/// Why an extension folder has no revision. Paths are relative to the folder.
public enum RevisionError: Error, Sendable, Equatable, CustomStringConvertible {
    case symlinkAbsolute(String)
    case symlinkOutside(String)
    case symlinkDangling(String)
    /// A FIFO, socket or device.
    case unsupportedFile(String)
    case unreadable(String)
    case tooLarge(limit: Int)
    case tooManyFiles(limit: Int)

    public var description: String {
        switch self {
        case .symlinkAbsolute(let path) where path.split(separator: "/").contains(".venv"):
            "\(path) is a symbolic link to an absolute path: a virtualenv can't be moved, so it can't be sealed; install Python packages into a folder instead (pip install --target vendor) and add it to sys.path"
        case .symlinkAbsolute(let path):
            "\(path) is a symbolic link to an absolute path; links must be relative and stay inside the folder"
        case .symlinkOutside(let path):
            "\(path) is a symbolic link out of the folder, or into a folder the revision skips (such as .git); copy what it points to into the folder instead"
        case .symlinkDangling(let path): "\(path) is a symbolic link to nothing; remove it"
        case .unsupportedFile(let path): "\(path) is not a regular file, folder or symbolic link"
        case .unreadable(let path): "\(path) can't be read"
        case .tooLarge(let limit):
            "the folder holds over \(limit >> 20) MiB (dependencies included; not counting .git, __pycache__ and .claude); move data to WICKET_DATA_DIR"
        case .tooManyFiles(let limit):
            "the folder holds over \(limit) files (dependencies included; not counting .git, __pycache__ and .claude)"
        }
    }
}

extension ExtensionRevision {
    /// Names skipped at any depth: tool state and regenerable caches, never what runs. Dependencies
    /// (`node_modules`, vendored packages) run, so they count.
    public static let skippedNames: Set<String> = [".git", "__pycache__", ".claude", ".DS_Store"]
    /// Bounds outside the skipped names, dependencies included: room for a typical node_modules or
    /// vendored Python packages, while keeping sealing and hashing well under a second.
    public static let byteLimit = 256 << 20
    public static let fileLimit = 20_000

    /// The revision of the extension `id` in `folder`: SHA-256 over every file and symbolic link
    /// except `skippedNames`, sorted by relative path (UTF-8 bytes), each as its kind, its path, and
    /// then a file's executable bit and bytes or a link's target as written, every field length-
    /// prefixed so no two folders encode alike. Folders count only through what they hold, and
    /// permissions only through the executable bit (umask and read-only sealing change nothing).
    ///
    /// A symbolic link must be relative and resolve inside the folder, outside the skipped names:
    /// otherwise it would run code the hash never saw, and an absolute one breaks when the folder
    /// is sealed by copying. Throws `RevisionError`. Off the main actor, never on a keystroke.
    public init(folder: URL, id: String) throws(RevisionError) {
        self = try RevisionTree(folder).revision(id: id)
    }
}

/// A folder as a revision counts it: its files, links and folders outside the skipped names, with
/// links checked and bounds enforced (by `lstat` size, before anything is read). Sealing walks the
/// authoring folder with it, copies what it lists, and hashes the copy with it again.
struct RevisionTree {
    enum Kind { case file, link, folder }

    let root: URL
    /// Sorted by relative path as UTF-8 bytes.
    let entries: [(path: String, kind: Kind)]

    init(_ folder: URL) throws(RevisionError) {
        let rootPath = folder.standardizedFileURL.path
        guard let realRoot = Self.realpath(rootPath) else { throw .unreadable(".") }
        root = URL(filePath: rootPath, directoryHint: .isDirectory)
        var entries: [(path: String, kind: Kind)] = []
        var files = 0
        var bytes = 0
        func walk(_ directory: URL, _ relative: String) throws(RevisionError) {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw .unreadable(relative.isEmpty ? "." : relative)
            }
            for name in names where !ExtensionRevision.skippedNames.contains(name) {
                let path = relative.isEmpty ? name : relative + "/" + name
                let url = directory.appending(path: name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw .unreadable(path) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    entries.append((path, .folder))
                    try walk(url, path)
                case S_IFREG, S_IFLNK:
                    let isLink = info.st_mode & S_IFMT == S_IFLNK
                    if isLink { try Self.checkLink(url, path: path, inside: realRoot) }
                    entries.append((path, isLink ? .link : .file))
                    files += 1
                    guard files <= ExtensionRevision.fileLimit else {
                        throw .tooManyFiles(limit: ExtensionRevision.fileLimit)
                    }
                    bytes += Int(info.st_size)
                    guard bytes <= ExtensionRevision.byteLimit else {
                        throw .tooLarge(limit: ExtensionRevision.byteLimit)
                    }
                default:
                    throw .unsupportedFile(path)
                }
            }
        }
        try walk(root, "")
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        self.entries = entries
    }

    /// Hashes what the tree lists, as `ExtensionRevision.init(folder:id:)` documents.
    func revision(id: String) throws(RevisionError) -> ExtensionRevision {
        var hash = SHA256()
        hash.update(data: Data("wicket-revision-1".utf8))
        for (path, kind) in entries where kind != .folder {
            let url = root.appending(path: path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw .unreadable(path) }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                    throw .unreadable(path)
                }
                Self.field(&hash, Data("l".utf8))
                Self.field(&hash, Data(path.utf8))
                Self.field(&hash, Data(target.utf8))
            } else {
                guard info.st_mode & S_IFMT == S_IFREG,
                    let contents = try? Data(contentsOf: url, options: .alwaysMapped)
                else { throw .unreadable(path) }
                Self.field(&hash, Data("f".utf8))
                Self.field(&hash, Data(path.utf8))
                Self.field(&hash, Data((info.st_mode & 0o111 != 0 ? "x" : "-").utf8))
                Self.field(&hash, contents)
            }
        }
        return ExtensionRevision(
            extensionID: id, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Copies what the tree lists into `destination` (which must not exist): folders, then files
    /// and links as themselves (an APFS clone where possible, so dependencies cost no space), then
    /// takes every write permission away, deepest folder first. Execute bits stay.
    func copy(to destination: URL) throws(RevisionError) {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw .unreadable(".")
        }
        for (path, kind) in entries {
            let target = destination.appending(path: path).path
            switch kind {
            case .folder:
                guard mkdir(target, 0o755) == 0 else { throw .unreadable(path) }
            case .file, .link:
                // A clone, else a copy; links are copied as links, never followed.
                guard
                    copyfile(root.appending(path: path).path, target, nil, copyfile_flags_t(COPYFILE_CLONE))
                        == 0
                else { throw .unreadable(path) }
                if kind == .file {
                    var info = stat()
                    guard lstat(target, &info) == 0, chmod(target, info.st_mode & 0o555) == 0 else {
                        throw .unreadable(path)
                    }
                }
            }
        }
        let folders = entries.filter { $0.kind == .folder }.map(\.path).sorted { $0.count > $1.count }
        for path in folders where chmod(destination.appending(path: path).path, 0o555) != 0 {
            throw .unreadable(path)
        }
        guard chmod(destination.path, 0o555) == 0 else { throw .unreadable(".") }
    }

    /// Throws unless the link at `url` is relative and resolves inside `root`, outside the skipped
    /// names.
    private static func checkLink(_ url: URL, path: String, inside root: String) throws(RevisionError) {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            throw .unreadable(path)
        }
        guard !target.hasPrefix("/") else { throw .symlinkAbsolute(path) }
        // Resolved for real, not lexically: a link through another link can climb out of the folder
        // while its spelling stays inside.
        guard let resolved = realpath(url.path) else { throw .symlinkDangling(path) }
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw .symlinkOutside(path) }
        // What a skipped folder holds isn't hashed or sealed, so a link into one would run unsealed
        // code too.
        let inside = resolved.dropFirst(root.count).split(separator: "/").map(String.init)
        guard ExtensionRevision.skippedNames.isDisjoint(with: inside) else { throw .symlinkOutside(path) }
    }

    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A length-prefixed field (8 bytes, little-endian).
    private static func field(_ hash: inout SHA256, _ data: Data) {
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { hash.update(bufferPointer: $0) }
        hash.update(data: data)
    }
}
