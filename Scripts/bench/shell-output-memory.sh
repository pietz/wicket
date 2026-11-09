#!/bin/zsh
# Off-screen regression check: the actual OutputTail must bound memory before queueing output.
set -euo pipefail
cd "${0:A:h}/../.."
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
{
  print 'import Darwin\nimport Foundation\nimport Synchronization'
  sed -n '/^\/\/\/ The last `limit` bytes/,$p' Sources/WicketHost/ProcessTree.swift
  cat <<'SWIFT'
@main struct Main {
    static func main() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/yes")
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let output = OutputTail(limit: 16 << 10)
        try process.run()
        let reading = Task.detached { await output.drain(pipe.fileHandleForReading) }
        var usage = rusage()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            usleep(20_000)
            getrusage(RUSAGE_SELF, &usage)
            // Fail early rather than let a regression exhaust the owner's RAM.
            if usage.ru_maxrss > 128 << 20 { break }
        }
        process.terminate()
        process.waitUntilExit()
        await reading.value
        getrusage(RUSAGE_SELF, &usage)
        print("Peak RSS: \(usage.ru_maxrss) bytes; output: \(output.text.utf8.count) bytes")
        guard usage.ru_maxrss < 128 << 20, output.text.utf8.count == 16 << 10, output.truncated else {
            print("FAILED: noisy shell output exceeded the memory or output bound")
            exit(1)
        }
    }
}
SWIFT
} > "$stage/main.swift"
swiftc -swift-version 6 -O -parse-as-library "$stage/main.swift" -o "$stage/probe"
"$stage/probe"
