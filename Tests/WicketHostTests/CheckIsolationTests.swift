import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

// `wicket check` is the gate before agent-written code is approved, so it must never run that code
// with the user's secrets, environment, files or network. These run real processes in the sandbox.

/// One request whose answer's title is whatever `title` (shell) prints, and a fixture expecting
/// `expected`, so a mismatch reports both.
private func probe(_ title: String, expecting expected: String, secrets: String = "[]") throws
    -> TestExtension
{
    let script = #"""
        read -r line
        title=$(\#(title))
        printf '{"jsonrpc":"2.0","id":1,"result":{"answer":{"title":"%s"}}}\n' "$title"
        """#
    let fixture = send(1) + "\n" + #"{"expect":{"id":1,"result":{"answer":{"title":"\#(expected)"}}}}"#
    return try TestExtension(secrets: secrets, script: script, fixture: fixture)
}

@Test func secretsArePlaceholdersAndTheEnvironmentIsMinimal() async throws {
    // sh adds PWD, SHLVL and _ itself.
    let ext = try probe(
        #"env | cut -d= -f1 | grep -vx -e PWD -e SHLVL -e _ | sort | tr '\n' ' '; printf '%s' "$TOKEN""#,
        expecting:
            "HOME LANG PATH TMPDIR TOKEN WICKET_CHECK WICKET_DATA_DIR WICKET_EXTENSION_ID WICKET_PROTOCOL "
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
    let profile = CheckIsolation.profile(writable: [#"/tmp/a "b" \c"#])
    #expect(profile.contains(#"(subpath "/tmp/a \"b\" \\c")"#))
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
