import Darwin
import Foundation

/// The user's login-shell environment, so extensions find `python3`, `node` and Homebrew tools as in
/// Terminal even though Wicket is started by launchd with a minimal PATH.
public enum LoginShell {
    /// Used when the shell can't be asked or doesn't answer in time.
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The login shell's PATH, resolved once per process.
    public static func path() async -> String { await resolved.value }

    private static let resolved = Task.detached(priority: .userInitiated) { await resolve() }

    private static func resolve() async -> String {
        let marker = "__WICKET_PATH__"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        // Interactive too: many people set PATH in .zshrc, which only interactive shells read. The
        // markers skip anything the startup files print.
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return fallbackPath }
        let pid = process.processIdentifier
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            kill(pid, SIGKILL)
        }
        defer { deadline.cancel() }
        var data = Data()
        for await chunk in output.fileHandleForReading.chunks() { data.append(chunk) }
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return fallbackPath }
        return parts[1]
    }

    /// `$SHELL`, else the account's shell (launchd doesn't set SHELL), else zsh.
    private static var shell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }
}
