import Darwin
import Foundation
import WicketCore

/// Where `wicket check` runs candidate code: a scratch folder holding a sealed copy of the candidate,
/// its own home, temp and data folders, and a sandbox profile that keeps the process inside them.
///
/// The candidate never sees the user's secrets, environment or files to write: declared secrets are
/// placeholders, the environment is built from nothing, and the process runs under `sandbox-exec`
/// with no network and no writes outside the scratch folders. If the sandbox can't be applied the
/// check fails; nothing runs unsandboxed.
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

    /// Copies `folder` into a fresh scratch folder.
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
            try Data(Self.profile(writable: [home.path, temporary.path, data.path]).utf8).write(to: profile)
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
        ]
        configuration.wrapper = [Self.sandboxExecutable.path, "-f", profile.path]
        configuration.idleTimeout = nil
        return configuration
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
    /// allowed, minus the ways out. No network (including local sockets), no writes outside
    /// `writable`, no Keychain or pasteboard services, no Apple events to other apps and no
    /// LaunchServices opens (which would hand a URL to the browser outside the sandbox).
    static func profile(writable: [String]) -> String {
        let folders = writable.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
            (version 1)
            (allow default)
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
