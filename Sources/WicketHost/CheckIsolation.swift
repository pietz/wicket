import Darwin
import Foundation
import WicketCore

/// Where `wicket check` runs candidate code: the sealed revision's read-only folder, a scratch folder
/// with its own home, temp and data folders, and a sandbox profile that keeps the process inside them.
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
    /// The sealed revision's folder, with symlinks resolved: read-only, readable in the sandbox.
    let candidate: URL
    let home: URL
    let temporary: URL
    let data: URL
    let profile: URL
    /// A uv extension's uv cache for the check: a clone of Wicket's (`UVStorage.cache`) that the
    /// check prepares and the candidate uses, so neither can change Wicket's own.
    let uvCache: URL
    /// The profile `prepareUV` installs dependencies under: `profile` with the network allowed.
    let prepareProfile: URL

    /// The user's home folder, with symlinks resolved; no candidate reads it.
    static var userHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return realPath(home) ?? home
    }

    /// A fresh scratch folder for checking `candidate`, a sealed revision's read-only folder, in
    /// place. The sandbox profile is written by `seal`.
    init(candidate folder: URL) throws(CheckIsolationError) {
        guard let candidate = Self.realPath(folder.path) else {
            throw .setup("could not resolve the sealed folder")
        }
        self.candidate = URL(filePath: candidate, directoryHint: .isDirectory)
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
        home = scratch.appending(path: "home", directoryHint: .isDirectory)
        temporary = scratch.appending(path: "tmp", directoryHint: .isDirectory)
        data = scratch.appending(path: "data", directoryHint: .isDirectory)
        profile = scratch.appending(path: "sandbox.sb")
        uvCache = scratch.appending(path: "uv-cache", directoryHint: .isDirectory)
        prepareProfile = scratch.appending(path: "prepare.sb")
        do {
            for directory in [home, temporary, data] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            remove()
            throw .setup("could not create a scratch folder: \(error.localizedDescription)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The session configuration for the candidate: placeholder secrets, a minimal environment,
    /// scratch data, and the sandbox around the process. A uv extension's uv uses the check's cache
    /// (`uvCache`) and `uv`'s Pythons, offline.
    func configuration(version: String, uv: UVStorage? = nil) -> SessionConfiguration {
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
        if let uv {
            configuration.uv = UVStorage(cache: uvCache, python: uv.python)
            configuration.uvOffline = true
        }
        return configuration
    }

    /// Writes the sandbox profile for running `program` (resolved from `run`, nil if it wasn't
    /// found): it may read the scratch folder, the candidate and what `program` needs
    /// (`ProgramReads`), and none of the user's files (`privateRoots(home:)`). For a uv extension
    /// (`uv` given) it may also read Wicket's Pythons and write the check's uv cache, and
    /// `prepareProfile` is written too: the same with the network allowed.
    func seal(program: URL?, userHome: String = userHome, uv: UVStorage? = nil) throws(CheckIsolationError) {
        let reads = program.map { ProgramReads($0.path, home: userHome) } ?? ProgramReads()
        var writable = [home.path, temporary.path, data.path]
        var readable = [scratch.path, candidate.path] + reads.folders
        if let uv {
            // Resolved, since the sandbox matches resolved paths; created, so it resolves.
            try? FileManager.default.createDirectory(at: uv.python, withIntermediateDirectories: true)
            guard let python = Self.realPath(uv.python.path) else {
                throw .setup("could not resolve Wicket's uv Python folder")
            }
            readable.append(python)
            writable.append(uvCache.path)
        }
        func text(network: Bool) -> String {
            Self.profile(
                writable: writable, private: Self.privateRoots(home: userHome), readable: readable,
                paths: reads.paths, network: network)
        }
        do {
            try Data(text(network: false).utf8).write(to: profile)
            if uv != nil { try Data(text(network: true).utf8).write(to: prepareProfile) }
        } catch {
            throw .setup("could not write the sandbox profile: \(error.localizedDescription)")
        }
    }

    /// Readies a uv extension's check, before the candidate runs: `script`'s lock must exist;
    /// Wicket's uv cache is cloned into `uvCache` (an APFS clone, so it costs neither time nor
    /// space); `uv` (the login shell's, never one the extension names) installs the Python the
    /// script asks for into Wicket's storage, outside the sandbox, since that reads only the
    /// script's `requires-python` and runs no package; then installs the locked dependencies into
    /// the clone inside the sandbox with the network allowed (`prepareProfile`), since uv may start
    /// the environment's Python, which runs code its packages install (a `.pth` file). The replay
    /// then runs offline against the clone, so neither step nor the candidate can change Wicket's
    /// cache, and the candidate can't change its Pythons.
    func prepareUV(
        script: String, uv: URL, storage: UVStorage, path: String, timeout: Duration,
        sandbox: URL = sandboxExecutable
    ) async throws(CheckIsolationError) {
        guard FileManager.default.fileExists(atPath: UV.lockFile(of: script, in: candidate).path) else {
            throw .uv(UV.missingLock(script))
        }
        try cloneUVCache(storage.cache)
        let environment = UV.environment(
            ["PATH": path, "HOME": home.path, "TMPDIR": temporary.path + "/"],
            storage: UVStorage(cache: uvCache, python: storage.python), mode: .run)
        let python = await UV.execute(
            uv, ["python", "find", "--script", script], in: candidate, environment: environment,
            timeout: timeout)
        guard python.succeeded else {
            throw .uv(
                "uv couldn't find or install the Python \(script) asks for (its requires-python):\n\(python.output)"
            )
        }
        let sync = await UV.execute(
            uv, ["sync", "--script", script, "--locked", "--no-build"], in: candidate,
            environment: environment,
            wrapper: [sandbox.path, "-f", prepareProfile.path], timeout: timeout)
        guard sync.succeeded else { throw .uv(UV.installFailure(sync.output, script: script)) }
    }

    /// `uvCache` as a clone of `cache`, or empty if Wicket has none yet.
    private func cloneUVCache(_ cache: URL) throws(CheckIsolationError) {
        if FileManager.default.fileExists(atPath: cache.path) {
            // A clone of the whole tree in one call; a plain copy where the volume can't clone.
            if clonefile(cache.path, uvCache.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
            try? FileManager.default.removeItem(at: uvCache)
            do {
                try FileManager.default.copyItem(at: cache, to: uvCache)
                return
            } catch {
                throw .setup("could not copy Wicket's uv cache: \(error.localizedDescription)")
            }
        }
        do {
            try FileManager.default.createDirectory(at: uvCache, withIntermediateDirectories: true)
        } catch {
            throw .setup("could not create the check's uv cache: \(error.localizedDescription)")
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
        writable: [String], private: [String] = [], readable: [String] = [], paths: [String] = [],
        network: Bool = false
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
            \(network ? "; the network is allowed (installing dependencies)" : "(deny network*)")
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
    /// A uv extension's dependencies couldn't be prepared; uv's words and what to do.
    case uv(String)

    var description: String {
        switch self {
        case .setup(let message), .uv(let message): message
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
