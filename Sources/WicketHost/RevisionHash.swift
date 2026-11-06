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
        case .symlinkAbsolute(let path):
            "\(path) is a symbolic link to an absolute path; links must be relative and stay inside the folder"
        case .symlinkOutside(let path):
            "\(path) is a symbolic link out of the folder, or into a folder the revision skips (such as node_modules); copy what it points to into the folder instead"
        case .symlinkDangling(let path): "\(path) is a symbolic link to nothing; remove it"
        case .unsupportedFile(let path): "\(path) is not a regular file, folder or symbolic link"
        case .unreadable(let path): "\(path) can't be read"
        case .tooLarge(let limit):
            "the folder holds over \(limit >> 20) MiB (not counting .git, node_modules, .venv, __pycache__ and .claude); move data to WICKET_DATA_DIR"
        case .tooManyFiles(let limit):
            "the folder holds over \(limit) files (not counting .git, node_modules, .venv, __pycache__ and .claude)"
        }
    }
}

extension ExtensionRevision {
    /// Names skipped at any depth: tool state and caches, never the code that runs.
    public static let skippedNames: Set<String> = [
        ".git", "node_modules", ".venv", "__pycache__", ".claude", ".DS_Store",
    ]
    public static let byteLimit = 32 << 20
    public static let fileLimit = 5000

    /// The revision of the extension `id` in `folder`: SHA-256 over every file and symbolic link
    /// except `skippedNames`, sorted by relative path (UTF-8 bytes), each as its kind, its path, and
    /// then a file's executable bit and bytes or a link's target as written, every field length-
    /// prefixed so no two folders encode alike. Folders count only through what they hold, and
    /// permissions only through the executable bit (umask differences change nothing else).
    ///
    /// A symbolic link must be relative and resolve inside the folder, outside the skipped names:
    /// otherwise it would run code the hash never saw, and an absolute one breaks when the folder
    /// is copied. Its target is hashed as written; what it points to is hashed as itself. Throws
    /// `RevisionError`. Load time only (`Extensions.load`), never on a keystroke.
    public init(folder: URL, id: String) throws(RevisionError) {
        let root = folder.standardizedFileURL.path
        guard let realRoot = Self.realpath(root) else { throw .unreadable(".") }
        var entries: [(path: String, url: URL)] = []
        var bytes = 0
        func walk(_ directory: URL, _ relative: String) throws(RevisionError) {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw .unreadable(relative.isEmpty ? "." : relative)
            }
            for name in names where !Self.skippedNames.contains(name) {
                let path = relative.isEmpty ? name : relative + "/" + name
                let url = directory.appending(path: name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw .unreadable(path) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    try walk(url, path)
                case S_IFREG, S_IFLNK:
                    entries.append((path, url))
                    guard entries.count <= Self.fileLimit else { throw .tooManyFiles(limit: Self.fileLimit) }
                    bytes += Int(info.st_size)
                    guard bytes <= Self.byteLimit else { throw .tooLarge(limit: Self.byteLimit) }
                default:
                    throw .unsupportedFile(path)
                }
            }
        }
        try walk(URL(filePath: root, directoryHint: .isDirectory), "")
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }

        var hash = SHA256()
        hash.update(data: Data("wicket-revision-1".utf8))
        for (path, url) in entries {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw .unreadable(path) }
            if info.st_mode & S_IFMT == S_IFLNK {
                let target = try Self.linkTarget(url, path: path, inside: realRoot)
                Self.field(&hash, Data("l".utf8))
                Self.field(&hash, Data(path.utf8))
                Self.field(&hash, Data(target.utf8))
            } else {
                guard let contents = try? Data(contentsOf: url, options: .alwaysMapped) else {
                    throw .unreadable(path)
                }
                Self.field(&hash, Data("f".utf8))
                Self.field(&hash, Data(path.utf8))
                Self.field(&hash, Data((info.st_mode & 0o111 != 0 ? "x" : "-").utf8))
                Self.field(&hash, contents)
            }
        }
        self.init(
            extensionID: id, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// The link's target as written, once it is known to be relative and to resolve inside `root`.
    private static func linkTarget(_ url: URL, path: String, inside root: String) throws(RevisionError)
        -> String
    {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            throw .unreadable(path)
        }
        guard !target.hasPrefix("/") else { throw .symlinkAbsolute(path) }
        // Resolved for real, not lexically: a link through another link can climb out of the folder
        // while its spelling stays inside.
        guard let resolved = realpath(url.path) else { throw .symlinkDangling(path) }
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw .symlinkOutside(path) }
        // What a skipped folder holds isn't hashed, so a link into one would run unsealed code too.
        let inside = resolved.dropFirst(root.count).split(separator: "/").map(String.init)
        guard skippedNames.isDisjoint(with: inside) else { throw .symlinkOutside(path) }
        return target
    }

    private static func realpath(_ path: String) -> String? {
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
