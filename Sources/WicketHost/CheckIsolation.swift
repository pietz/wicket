import Darwin
import Foundation
import WicketCore

/// Where `wicket check` runs candidate code: a scratch folder holding a sealed copy of the candidate,
/// its own home, temp and data folders, and a sandbox profile that keeps the process inside them.
///
/// The candidate never sees the user's secrets, environment or files: declared secrets are
/// placeholders, the environment is built from nothing, and the process runs under `sandbox-exec`
/// with no network, no writes outside the scratch folders and no reads of the user's files (homes,
/// other volumes, temp folders) beyond the scratch folder and the program `run` names. If the
/// sandbox can't be applied the check fails; nothing runs unsandboxed.
struct CheckIsolation {
    /// What every declared secret is set to while checking.
    static let placeholderSecret = "wicket-check-placeholder"
    static let sandboxExecutable = URL(filePath: "/usr/bin/sandbox-exec")

    /// The scratch folder, with symlinks resolved (the sandbox matches resolved paths).
    let scratch: URL
    /// The sealed copy of the candidate, under its original folder name.
    let candidate: URL
    let home: URL
    let temporary: URL
    let data: URL
    let profile: URL

    /// The user's home folder, with symlinks resolved; no candidate reads it.
    static var userHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return realPath(home) ?? home
    }

    /// Copies `folder` into a fresh scratch folder. The sandbox profile is written by `seal`.
    init(sealing folder: URL) throws(CheckIsolationError) {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "wicket-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw .setup("could not create a scratch folder: \(error.localizedDescription)")
        }
        guard let resolved = Self.realPath(base.path) else {
            try? FileManager.default.removeItem(at: base)
            throw .setup("could not resolve the scratch folder")
        }
        scratch = URL(filePath: resolved, directoryHint: .isDirectory)
        candidate = scratch.appending(path: "candidate/\(folder.standardizedFileURL.lastPathComponent)")
        home = scratch.appending(path: "home", directoryHint: .isDirectory)
        temporary = scratch.appending(path: "tmp", directoryHint: .isDirectory)
        data = scratch.appending(path: "data", directoryHint: .isDirectory)
        profile = scratch.appending(path: "sandbox.sb")
        do {
            for directory in [home, temporary, data, candidate.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: folder, to: candidate)
        } catch {
            remove()
            throw .setup("could not copy the extension into a scratch folder: \(error.localizedDescription)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The session configuration for the candidate: placeholder secrets, a minimal environment,
    /// scratch data, and the sandbox around the process.
    func configuration(version: String) -> SessionConfiguration {
        var configuration = SessionConfiguration(dataDirectory: data, version: version) { _ in
            Self.placeholderSecret
        }
        configuration.environment = [
            "HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "WICKET_CHECK": "1",
            // swift keeps compiled modules in the per-user cache folder, which the candidate can't
            // read; this keeps them in scratch instead.
            "CLANG_MODULE_CACHE_PATH": temporary.path + "/clang-module-cache",
        ]
        configuration.wrapper = [Self.sandboxExecutable.path, "-f", profile.path]
        configuration.idleTimeout = nil
        return configuration
    }

    /// Writes the sandbox profile for running `program` (resolved from `run`, nil if it wasn't
    /// found): it may read the scratch folder and what `program` needs (`ProgramReads`), and none of
    /// the user's files (`privateRoots(home:)`).
    func seal(program: URL?, userHome: String = userHome) throws(CheckIsolationError) {
        let reads = program.map { ProgramReads($0.path, home: userHome) } ?? ProgramReads()
        let text = Self.profile(
            writable: [home.path, temporary.path, data.path], private: Self.privateRoots(home: userHome),
            readable: [scratch.path] + reads.folders, paths: reads.paths)
        do {
            try Data(text.utf8).write(to: profile)
        } catch {
            throw .setup("could not write the sandbox profile: \(error.localizedDescription)")
        }
    }

    /// Where the user's files are: every home, other volumes, and the shared and per-user temp
    /// folders (which hold other apps' caches). The candidate reads none of it, except what `seal`
    /// allows back. Everything else (the system, /Applications, /opt/homebrew, /usr/local, Xcode
    /// and the Command Line Tools) stays readable, so interpreters and tools start as usual.
    static func privateRoots(home: String) -> [String] {
        let roots = ["/Users", "/Volumes", "/private/var/folders", "/private/tmp", "/private/var/tmp"]
        return roots.contains(where: { home == $0 || home.hasPrefix($0 + "/") }) ? roots : roots + [home]
    }

    /// Applies the profile to `/usr/bin/true`, so a sandbox that can't be applied (sandbox-exec
    /// missing, or Wicket itself running sandboxed) fails the check before candidate code runs.
    func verifySandbox(executable: URL = sandboxExecutable) throws(CheckIsolationError) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-f", profile.path, "/usr/bin/true"]
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw .sandbox("could not start \(executable.path): \(error.localizedDescription)")
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw .sandbox(
                "\(executable.lastPathComponent) exited with status \(process.terminationStatus)"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    /// The sandbox profile: everything a script or interpreter needs to start and compute is
    /// allowed, minus the ways out. No reads under `private` except the folders in `readable` and
    /// the single files in `paths` (exec follows each link, so each must be readable), and of
    /// their folders only the metadata; no network
    /// (including local sockets), no writes outside `writable`, no Keychain or pasteboard services,
    /// no Apple events to other apps and no LaunchServices opens (which would hand a URL to the
    /// browser outside the sandbox). Later rules win, so each allow follows the deny it narrows.
    static func profile(
        writable: [String], private: [String] = [], readable: [String] = [], paths: [String] = []
    ) -> String {
        let folders = writable.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        let hidden = `private`.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        let shown = (readable.map { "(subpath \(quoted($0)))" } + paths.map { "(literal \(quoted($0)))" })
            .joined(separator: " ")
        // Their folders' own metadata (not their listings), since resolving a path, as Node and
        // swift do with the working directory, looks at every folder on the way.
        var ancestors: Set<String> = []
        for path in readable + paths {
            var folder = URL(filePath: path).deletingLastPathComponent()
            while folder.path != "/", ancestors.insert(folder.path).inserted {
                folder = folder.deletingLastPathComponent()
            }
        }
        let above = ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")
        return """
            (version 1)
            (allow default)
            (deny file-read* \(hidden))
            (allow file-read* \(shown)
              (literal "/private/var/tmp") (regex #"^/private/var/tmp/sh-thd-[0-9]+$"))
            (allow file-read-metadata \(above))
            (deny network*)
            (deny file-write*)
            (allow file-write* \(folders)
              (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper")
              (literal "/dev/stdout") (literal "/dev/stderr") (regex #"^/dev/fd/[0-9]+$")
              ; /bin/sh (bash 3.2) writes here-documents to /var/tmp whatever TMPDIR says.
              (literal "/private/var/tmp") (regex #"^/private/var/tmp/sh-thd-[0-9]+$"))
            (deny mach-lookup
              (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc")
              (global-name "com.apple.pasteboard.1"))
            (deny appleevent-send)
            (deny lsopen)

            """
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// `path` with every symlink resolved, such as /var to /private/var. (`URL.resolvingSymlinksInPath`
    /// maps /private/var back to /var, which the sandbox wouldn't match.)
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum CheckIsolationError: Error, CustomStringConvertible {
    case setup(String)
    case sandbox(String)

    var description: String {
        switch self {
        case .setup(let message): message
        case .sandbox(let message):
            "the check sandbox could not be applied (\(message)); nothing was run, since a check never runs code unsandboxed"
        }
    }
}

/// What running a program needs to read where the candidate otherwise may not (`privateRoots`):
/// each symbolic link on the way to it, and the folder it is installed in. A uv, pyenv, nvm or
/// Volta interpreter under the home folder then starts, while the rest of the home stays unreadable.
struct ProgramReads: Equatable {
    /// Folders readable as a whole.
    var folders: [String] = []
    /// Single paths readable themselves, not what is beside them: the links, and the program when
    /// its folder can't be taken whole.
    var paths: [String] = []

    init() {}

    /// The install folder of the real file is the one above its `bin` (or `shims`, `sbin`), so the
    /// interpreter finds its libraries; a folder holding unrelated tools and data (the home itself,
    /// `~/.local`, `~/.local/share`, `~/Library`, `~/.config`) is never taken whole: then only the
    /// folder the program is in is readable, or the program alone if that folder is one of them.
    init(_ path: String, home: String) {
        var path = URL(filePath: path).standardized.path
        // Follows one link at a time, from the root down, so links inside a link's target count too.
        var hops = 0
        outer: while hops < 32 {
            var walked = ""
            let components = path.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                walked += "/" + component
                guard let target = Self.linkTarget(walked) else { continue }
                paths.append(walked)
                let base = URL(filePath: walked).deletingLastPathComponent()
                let resolved = target.hasPrefix("/") ? URL(filePath: target) : base.appending(path: target)
                let rest = components[(index + 1)...].joined(separator: "/")
                path = (rest.isEmpty ? resolved : resolved.appending(path: rest)).standardized.path
                hops += 1
                continue outer
            }
            break
        }
        let folder = URL(filePath: path).deletingLastPathComponent()
        let generic = [home, home + "/.local", home + "/.local/share", home + "/Library", home + "/.config"]
        var install = folder.path
        if ["bin", "sbin", "shims"].contains(folder.lastPathComponent) {
            let above = folder.deletingLastPathComponent().path
            if !generic.contains(above), above != "/" { install = above }
        }
        if !generic.contains(install), install != "/" { folders.append(install) } else { paths.append(path) }
    }

    private static func linkTarget(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else { return nil }
        return target
    }
}
