import Foundation
import WicketCore

/// What `wicket check` found, line by line, for the agent or person fixing the extension.
public struct CheckReport: Sendable {
    public enum Kind: String, Sendable {
        case ok, warning, error
    }

    public struct Line: Sendable {
        public var kind: Kind
        public var text: String
    }

    public private(set) var lines: [Line] = []
    public var passed: Bool { !lines.contains { $0.kind == .error } }
    public var errors: [String] { lines.filter { $0.kind == .error }.map(\.text) }

    mutating func add(_ kind: Kind, _ text: String) {
        if kind == .warning, lines.contains(where: { $0.kind == .warning && $0.text == text }) { return }
        lines.append(Line(kind: kind, text: text))
    }
}

/// How `Checker.check` runs the candidate.
public struct CheckOptions: Sendable {
    /// `WICKET_VERSION`.
    public var version: String
    public var requestTimeout: Duration = .seconds(30)
    /// Time to exit after stdin closes, and again after SIGTERM before SIGKILL.
    public var exitGrace: Duration = .seconds(2)
    /// Tests point this elsewhere to see the check fail closed.
    var sandboxExecutable = CheckIsolation.sandboxExecutable
    /// The home folder the candidate may not read; tests point this at a folder of their own.
    var userHome = CheckIsolation.userHome
    /// Wicket's uv storage, which a uv extension's check clones and installs its Python into.
    var uv = UVStorage.standard
    /// How long each uv step preparing a check may take (it may download a Python and packages).
    var prepareTimeout: Duration = .seconds(300)

    public init(version: String) {
        self.version = version
    }
}

/// What the checker found about one sealed revision: the revision checked is the one that runs.
public struct CheckedRevision: Sendable {
    public let sealed: SealedRevision
    public let report: CheckReport
    public var passed: Bool { report.passed }
}

/// Validates an extension by running it the way Wicket does: the manifest, then every fixture
/// replayed against a fresh process, with every response checked against the protocol.
///
/// The check is the gate before code is approved, so it checks a sealed revision (the exact,
/// read-only bytes that would run) and is isolated (`CheckIsolation`): it runs in a sandbox, with
/// placeholder secrets, a minimal environment and scratch data, never the user's own. Without a
/// fixture nothing runs.
public enum Checker {
    /// Checks `sealed` in its retained folder.
    public static func check(_ sealed: SealedRevision, options: CheckOptions) async -> CheckedRevision {
        CheckedRevision(sealed: sealed, report: await report(sealed, options: options))
    }

    /// `wicket check <folder>`: seals the folder into a temporary store, checks that revision, and
    /// deletes the store. A folder that can't be sealed (no valid manifest, a bad link, too large)
    /// fails with why; a folder not named after its id only warns, since authors may work anywhere.
    public static func check(folder: URL, options: CheckOptions) async -> CheckReport {
        let store = RevisionStore.temporary()
        defer { store.removeAll() }
        let sealed: SealedRevision
        do {
            sealed = try store.seal(folder)
        } catch {
            var report = CheckReport()
            report.add(.error, error.description)
            return report
        }
        var report = await report(sealed, options: options)
        let folderName = folder.standardizedFileURL.lastPathComponent
        if folderName != sealed.manifest.id {
            report.add(
                .warning,
                "the folder is named \(folderName) but the id is \(sealed.manifest.id); installed extensions live in a folder named after the id"
            )
        }
        return report
    }

    private static func report(_ sealed: SealedRevision, options: CheckOptions) async -> CheckReport {
        var report = CheckReport()
        guard !Task.isCancelled else {
            report.add(.error, "Check cancelled.")
            return report
        }
        let manifest = sealed.manifest
        if manifest.commands.allSatisfy({ $0.prompt != nil }) {
            report.add(
                .ok,
                "wicket.json: \(manifest.id) \(manifest.version), \(manifest.commands.count) prompt commands")
            report.add(.ok, "Prompt templates validated; no process, AI request or fixture is needed.")
            return report
        }
        let isolation: CheckIsolation
        do {
            isolation = try CheckIsolation(candidate: sealed.folder)
        } catch {
            report.add(.error, error.description)
            return report
        }
        defer { isolation.remove() }
        let commands = manifest.commands.count
        report.add(
            .ok,
            "\(Manifest.fileName): \(manifest.id) \(manifest.version), \(commands) command\(commands == 1 ? "" : "s")"
        )

        let fixtures = fixtureFiles(in: isolation.candidate)
        for command in manifest.commands
        where !command.hidden && command.mode != .root && command.search.isEmpty {
            report.add(
                .warning,
                "wicket.json: command \(command.id) has no search terms; add search with words a person would type to find it"
            )
        }
        guard !fixtures.isEmpty else {
            report.add(
                .error,
                "no session.jsonl: add one with requests and the responses they should get; the check replays fixtures and runs nothing without one"
            )
            return report
        }
        // Not found: no reads for it, and the session reports it when it launches.
        let path = await LoginShell.path()
        let program = try? ExtensionSession.resolve(manifest.run[0], in: isolation.candidate, path: path)
        let uv = manifest.uvScript.map { _ in options.uv }
        guard !Task.isCancelled else {
            report.add(.error, "Check cancelled.")
            return report
        }
        do throws(CheckIsolationError) {
            try isolation.seal(program: program, userHome: options.userHome, uv: uv)
            try isolation.verifySandbox(executable: options.sandboxExecutable)
            if let script = manifest.uvScript {
                // `run` names uv alone, so this is the uv Wicket would prepare with.
                guard let program else { throw .uv(UV.Failure.noUV) }
                let start = ContinuousClock.now
                try await isolation.prepareUV(
                    script: script, uv: program, storage: options.uv, path: path,
                    timeout: options.prepareTimeout, sandbox: options.sandboxExecutable)
                report.add(.ok, "uv: installed what \(script).lock lists (\(seconds(since: start)) s)")
            }
        } catch {
            report.add(.error, error.description)
            return report
        }
        var configuration = isolation.configuration(version: options.version, uv: uv)
        configuration.requestTimeout = options.requestTimeout
        configuration.exitGrace = options.exitGrace
        for url in fixtures {
            guard !Task.isCancelled else {
                report.add(.error, "Check cancelled.")
                break
            }
            let name = url.lastPathComponent
            do {
                let fixture = try Fixture(String(decoding: try Data(contentsOf: url), as: UTF8.self))
                await replay(
                    fixture, name: name, manifest: manifest, folder: isolation.candidate,
                    configuration: configuration, into: &report)
            } catch let error as FixtureError {
                report.add(.error, "\(name):\(error.line): \(error.message)")
            } catch {
                report.add(.error, "\(name): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// `session.jsonl` and `*.session.jsonl` at the top of the folder.
    private static func fixtureFiles(in folder: URL) -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.lastPathComponent == "session.jsonl" || $0.lastPathComponent.hasSuffix(".session.jsonl")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct Sent {
        let line: Int
        let id: RequestID
        let command: String
        let reply: Task<Reply, any Error>
    }

    private static func replay(
        _ fixture: Fixture, name: String, manifest: Manifest, folder: URL,
        configuration: SessionConfiguration,
        into report: inout CheckReport
    ) async {
        let session = ExtensionSession(manifest: manifest, folder: folder, configuration: configuration)
        await withTaskCancellationHandler {
            await replay(fixture, name: name, manifest: manifest, session: session, into: &report)
        } onCancel: {
            Task { await session.stop() }
        }
        // Also await cleanup when cancellation arrived before the replay started.
        if Task.isCancelled { await session.stop() }
    }

    private static func replay(
        _ fixture: Fixture, name: String, manifest: Manifest, session: ExtensionSession,
        into report: inout CheckReport
    ) async {
        // A fixture must exercise the candidate: a launch and an answer, not just a clean parse.
        guard fixture.steps.contains(where: { if case .send(.run) = $0.step { true } else { false } }) else {
            report.add(
                .error,
                "\(name): sends no run, so nothing was checked; add a run and the response it should get")
            return
        }
        let start = ContinuousClock.now
        let errorsBefore = report.errors.count
        var lastExpect: [RequestID: Int] = [:]
        for (line, step) in fixture.steps {
            if case .expect(let id, _) = step { lastExpect[id] = line }
        }
        var sent: [RequestID: Sent] = [:]
        var matched = 0
        var answered = 0

        /// The reply to `request`, with protocol failures added to the report.
        func outcome(_ request: Sent, into report: inout CheckReport) async -> Reply? {
            do {
                let reply = try await request.reply.value
                answered += 1
                if case .success = reply.outcome, manifest.command(request.command) == nil {
                    report.add(
                        .error,
                        "\(name):\(request.line): run for \"\(request.command)\", which wicket.json doesn't declare, got a result; answer unknown commands with an error (code 1)"
                    )
                }
                if case .success(let result) = reply.outcome {
                    for problem in result.markupProblems {
                        report.add(.error, "\(name):\(request.line): \(request.command) \(problem)")
                    }
                }
                return reply
            } catch {
                report.add(
                    .error, "\(name):\(request.line): request \(request.id) (\(request.command)): \(error)")
                return nil
            }
        }

        for (line, step) in fixture.steps {
            guard !Task.isCancelled else { break }
            switch step {
            case .send(.run(let id, let params)):
                do {
                    guard manifest.command(params.command)?.prompt == nil else {
                        report.add(
                            .error,
                            "\(name):\(line): prompt commands are validated from the manifest; fixtures may only run program commands"
                        )
                        continue
                    }
                    // The same retry the app gives this command's runs; an undeclared one never.
                    let retry = manifest.command(params.command)?.retry ?? .never
                    let reply = try await session.submit(id, params, retry: retry)
                    sent[id] = Sent(line: line, id: id, command: params.command, reply: reply)
                } catch {
                    report.add(.error, "\(name):\(line): \(error)")
                }
            case .send(.cancel(let id)):
                if let expect = lastExpect[id], expect > line {
                    await session.notifyCancel(id)
                } else {
                    // Nothing waits for this answer, so the extension may skip it.
                    await session.cancel(id)
                    sent[id] = nil
                }
            case .expect(let id, let pattern):
                guard let request = sent.removeValue(forKey: id) else {
                    report.add(
                        .error,
                        "\(name):\(line): expects a response with id \(id), but no earlier line sends a run with that id"
                    )
                    continue
                }
                guard let reply = await outcome(request, into: &report) else { continue }
                let actual = (try? JSONDecoder().decode(JSONValue.self, from: Data(reply.line.utf8))) ?? .null
                if let mismatch = pattern.mismatch(in: actual) {
                    report.add(.error, "\(name):\(line): the response to id \(id) doesn't match: \(mismatch)")
                } else {
                    matched += 1
                }
            }
        }
        // Requests without an expect still need a valid response.
        for request in sent.values.sorted(by: { $0.line < $1.line }) {
            guard !Task.isCancelled else { break }
            _ = await outcome(request, into: &report)
        }
        if Task.isCancelled {
            await session.stop()
            report.add(.error, "\(name): check cancelled.")
            return
        }
        if answered == 0 {
            report.add(
                .error,
                "\(name): no run got a response, so nothing was checked; expect the response to at least one run"
            )
        }
        await finish(session, name: name, errorsBefore: errorsBefore, into: &report)
        if report.errors.count == errorsBefore {
            report.add(
                .ok,
                "\(name): \(fixture.steps.count) lines replayed, \(matched) expects matched (\(seconds(since: start)) s)"
            )
        }
    }

    /// Time since `start` in seconds, two decimals.
    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.2f", seconds)
    }

    /// Checks the process exits once stdin closes, reports what the session noticed on the way, and
    /// adds the end of stderr if anything since `errorsBefore` failed.
    private static func finish(
        _ session: ExtensionSession, name: String, errorsBefore: Int, into report: inout CheckReport
    ) async {
        // Shut down first: what the process does once its stdin closes counts too.
        let shutdown = await session.shutdown()
        for warning in await session.warnings { report.add(.warning, warning) }
        for issue in await session.issues { report.add(.error, "\(name): \(issue)") }
        switch shutdown {
        case .terminated, .killed:
            report.add(
                .error,
                "\(name): the process kept running 2 s after its stdin closed; exit when stdin reaches end of file"
            )
        case .exited(let exit) where !exit.isClean:
            report.add(.warning, "\(name): the process \(exit) after its stdin closed")
        default:
            break
        }
        let stderr = session.stderrTail.split(separator: "\n").suffix(20)
        if report.errors.count > errorsBefore, !stderr.isEmpty {
            report.add(
                .error, "\(name): the last stderr lines were:\n    " + stderr.joined(separator: "\n    "))
        }
    }
}
