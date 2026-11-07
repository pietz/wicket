import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// `wicket check` is the gate before agent-written code is approved, so it must never run that code
// with the user's secrets, environment, files or network. These run real processes in the sandbox.

/// One request whose answer's title is whatever `title` (shell) prints, and a fixture expecting
/// `expected`, so a mismatch reports both.
private func probe(
    _ title: String, expecting expected: String, secrets: String = "[]",
    run: String = #"["/bin/sh","main.sh"]"#
) throws -> TestExtension {
    let script = #"""
        read -r line
        title=$(\#(title))
        printf '{"jsonrpc":"2.0","id":1,"result":{"answer":{"title":"%s"}}}\n' "$title"
        """#
    let fixture = send(1) + "\n" + #"{"expect":{"id":1,"result":{"answer":{"title":"\#(expected)"}}}}"#
    return try TestExtension(secrets: secrets, run: run, script: script, fixture: fixture)
}

@Test func secretsArePlaceholdersAndTheEnvironmentIsMinimal() async throws {
    // sh adds PWD, SHLVL and _ itself.
    let ext = try probe(
        #"env | cut -d= -f1 | grep -vx -e PWD -e SHLVL -e _ | sort | tr '\n' ' '; printf '%s' "$TOKEN""#,
        expecting:
            "CLANG_MODULE_CACHE_PATH HOME LANG PATH TMPDIR TOKEN WICKET_CHECK WICKET_DATA_DIR WICKET_EXTENSION_ID WICKET_PROTOCOL "
            + "WICKET_VERSION \(CheckIsolation.placeholderSecret)",
        secrets: #"[{"name":"TOKEN","title":"API token"}]"#)
    let report = await check(ext)
    #expect(report.errors.isEmpty, "\(report.errors)")
}

@Test func homeTempAndDataAreScratchFolders() async throws {
    let ext = try probe(
        #"""
        for d in "$HOME" "$TMPDIR" "$WICKET_DATA_DIR"; do case "$d" in (*/wicket-check-*) printf s;; (*) printf x;; esac; done
        printf ' %s' "$WICKET_CHECK"
        """#,
        expecting: "sss 1")
    let report = await check(ext)
    #expect(report.errors.isEmpty, "\(report.errors)")
}

@Test func writesOutsideScratchFail() async throws {
    let outside = FileManager.default.temporaryDirectory.appending(path: "wicket-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let escaped = outside.appending(path: "escaped")
    // Outside, the candidate's own (sealed) folder, then the three scratch folders and a heredoc.
    let ext = try probe(
        #"""
        w() { if (echo x > "$1") 2>/dev/null; then printf ok; else printf no; fi; printf ' '; }
        w '\#(escaped.path)'; w ./written; w "$WICKET_DATA_DIR/d"; w "$HOME/h"; w "$TMPDIR/t"
        cat <<EOF
        heredoc
        EOF
        """#,
        expecting: "no no ok ok ok heredoc")
    let report = await check(ext)
    #expect(report.errors.isEmpty, "\(report.errors)")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(!FileManager.default.fileExists(atPath: ext.folder.appending(path: "written").path))
}

/// A stand-in home folder (symlinks resolved) holding a toolchain the way uv or nvm installs one:
/// `.local/bin/tool` links to `.local/share/tools/current/bin/tool`, `current` links to `v1`, and
/// the real `tool` is a shell script beside its `lib/data.txt`. Beside it, the user's files.
private struct FakeHome {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = try #require(CheckIsolation.realPath(base.path))
        for folder in [
            ".local/bin", ".local/share/tools/v1/bin", ".local/share/tools/v1/lib", ".local/share/other",
        ] {
            try FileManager.default.createDirectory(
                atPath: path + "/" + folder, withIntermediateDirectories: true)
        }
        try write("#!/bin/sh\nexec /bin/sh \"$@\"\n", to: ".local/share/tools/v1/bin/tool")
        chmod(path + "/.local/share/tools/v1/bin/tool", 0o755)
        try write("toolchain", to: ".local/share/tools/v1/lib/data.txt")
        try write("private", to: "secret.txt")
        try write("private", to: ".local/share/other/token")
        try FileManager.default.createSymbolicLink(
            atPath: path + "/.local/share/tools/current", withDestinationPath: "v1")
        try FileManager.default.createSymbolicLink(
            atPath: path + "/.local/bin/tool", withDestinationPath: "../share/tools/current/bin/tool")
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: URL(filePath: path + "/" + name))
    }
}

@Test func theProgramsLinksAndInstallFolderAreItsReads() throws {
    let home = try FakeHome()
    let reads = ProgramReads(home.path + "/.local/bin/tool", home: home.path)
    #expect(reads.paths == [home.path + "/.local/bin/tool", home.path + "/.local/share/tools/current"])
    #expect(reads.folders == [home.path + "/.local/share/tools/v1"])
    // Above its bin is a generic folder: only the bin is readable, not ~/.local.
    let loose = ProgramReads(home.path + "/.local/bin/other", home: home.path)
    #expect(loose.folders == [home.path + "/.local/bin"])
    #expect(loose.paths.isEmpty)
    // Right in the home: the program alone, never the home.
    let bare = ProgramReads(home.path + "/script", home: home.path)
    #expect(bare.folders.isEmpty)
    #expect(bare.paths == [home.path + "/script"])
}

@Test func theUsersFilesAreUnreadableButTheProgramsToolchainIsNot() async throws {
    let home = try FakeHome()
    let realHome = CheckIsolation.userHome
    // Its toolchain, then the fake home's files, the real home's listing, and the shared temp folder.
    let ext = try probe(
        #"""
        r() { if cat "$1" >/dev/null 2>&1; then printf ok; else printf no; fi; printf ' '; }
        r '\#(home.path)/.local/share/tools/v1/lib/data.txt'; r '\#(home.path)/secret.txt'
        r '\#(home.path)/.local/share/other/token'
        if ls '\#(realHome)' >/dev/null 2>&1; then printf ok; else printf no; fi
        if ls /tmp/ >/dev/null 2>&1; then printf ' ok'; else printf ' no'; fi
        """#,
        expecting: "ok no no no no", run: #"["\#(home.path)/.local/bin/tool","main.sh"]"#)
    // The control: outside the sandbox the same files are readable.
    #expect(FileManager.default.isReadableFile(atPath: home.path + "/secret.txt"))
    let report = await check(ext) { $0.userHome = home.path }
    #expect(report.errors.isEmpty, "\(report.errors)")
}

@Test func networkIsDenied() async throws {
    let listener = try Listener()
    defer { close(listener.socket) }
    let connect = "/usr/bin/nc -z -w 2 127.0.0.1 \(listener.port)"
    // The control: outside the sandbox the same command connects.
    let control = Process()
    control.executableURL = URL(filePath: "/bin/sh")
    control.arguments = ["-c", connect]
    try control.run()
    control.waitUntilExit()
    #expect(control.terminationStatus == 0)

    let ext = try probe(
        "if \(connect) 2>/dev/null; then printf connected; else printf blocked; fi", expecting: "blocked")
    let report = await check(ext)
    #expect(report.errors.isEmpty, "\(report.errors)")
}

@Test func withoutAFixtureNothingRuns() async throws {
    // Run, this would fail on the stray stdout line.
    let ext = try TestExtension(script: "echo stray; " + answering(#"{"close":{}}"#))
    let report = await check(ext)
    #expect(report.errors.count == 1)
    #expect(report.errors.first?.hasPrefix("no session.jsonl:") == true)
}

@Test func anUnavailableSandboxFailsClosed() async throws {
    let ext = try TestExtension(script: "echo stray; " + answering(#"{"close":{}}"#), fixture: send(1))
    let report = await check(ext) { $0.sandboxExecutable = URL(filePath: "/usr/bin/false") }
    #expect(report.errors.count == 1)
    #expect(report.errors.first?.contains("the check sandbox could not be applied") == true)
}

@Test func whatTheProcessWritesWhileShuttingDownIsReported() async throws {
    let ext = try TestExtension(script: answering(#"{"close":{}}"#) + "\necho goodbye", fixture: send(1))
    let errors = await check(ext).errors
    #expect(errors.contains { $0.contains(#"the extension wrote "goodbye"; write logs to stderr"#) })
}

@Test func theProfileEscapesPaths() {
    let profile = CheckIsolation.profile(writable: [#"/tmp/a "b" \c"#], private: ["/Users"])
    #expect(profile.contains(#"(subpath "/tmp/a \"b\" \\c")"#))
    #expect(profile.contains(#"(deny file-read* (subpath "/Users"))"#))
    #expect(profile.contains("(deny network*)"))
}

/// A TCP socket listening on a free loopback port, never accepting: connecting still succeeds.
private struct Listener {
    let socket: Int32
    let port: UInt16

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        self.socket = socket
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && listen(socket, 8) == 0
                    && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        port = UInt16(bigEndian: address.sin_port)
    }
}
