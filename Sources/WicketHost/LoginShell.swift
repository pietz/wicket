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
        // Interactive too: many people set PATH in .zshrc, which only interactive shells read. The
        // markers skip anything the startup files print.
        guard let (pid, output) = spawn(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]) else {
            return fallbackPath
        }
        let reading = Task<String?, Never> {
            var data = Data()
            for await chunk in output.chunks() {
                data.append(chunk)
                let parts = String(decoding: data, as: UTF8.self).components(separatedBy: marker)
                if parts.count >= 3 { return parts[1].isEmpty ? nil : parts[1] }
            }
            return nil
        }
        let path = await reading.value(within: .seconds(5)) ?? nil
        // A shell that didn't answer goes with whatever its startup files left in its session.
        if path == nil { kill(-pid, SIGKILL) }
        // waitpid blocks until the shell exits, so not on a cooperative thread.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return path ?? fallbackPath
    }

    /// Starts `executable` in a session of its own, with stdin and stderr on /dev/null and stdout a
    /// pipe it returns. Its own session means no controlling terminal: an interactive shell started
    /// from a process that has one (the CLI, or tests run in a terminal) would otherwise try to take
    /// the terminal from a background process group and be stopped by SIGTTIN until killed. Under
    /// launchd, the app has none either way. `posix_spawn`, since `Process` can't start a session.
    private static func spawn(_ executable: String, _ arguments: [String]) -> (pid_t, FileHandle)? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling and no blocked signals, as `Process` gives; only stdio inherited.
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                    | POSIX_SPAWN_SETSIGMASK))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(fds[1])
        guard status == 0 else {
            close(fds[0])
            return nil
        }
        return (pid, FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
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
