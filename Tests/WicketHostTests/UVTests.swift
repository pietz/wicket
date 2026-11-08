import CryptoKit
import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Python extensions run by uv (docs/extensions.md, "Python with uv"), against the real uv.

/// Real uv with one storage that every test shares and that outlives the run (in the temporary
/// folder), so its Python is downloaded once. A test extension's dependency is a wheel in its folder
/// (`Fixtures/uv`), so nothing else needs the network; the slugify sample's packages come from PyPI
/// and are fetched once into the same storage. Without uv, or offline before the storage has what a
/// test needs, the test is skipped (`Test.cancel`), never failed, so `Scripts/check.sh` doesn't
/// depend on the network.
enum UVTest {
    static let storage = UVStorage(
        root: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests-uv", directoryHint: .isDirectory))

    static var wheel: URL {
        get throws {
            try #require(
                Bundle.module.url(
                    forResource: "tiny-1.0-py3-none-any", withExtension: "whl", subdirectory: "Fixtures/uv"))
        }
    }

    /// Skips the calling test unless uv and the storage's Python are ready.
    static func require() async throws {
        if let reason = await ready.value { try Test.cancel(Comment(rawValue: reason)) }
    }

    /// The environment the tests' own uv steps get: the login PATH and the test storage.
    static func environment(_ mode: UV.Mode = .run) async -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        base["PATH"] = await LoginShell.path()
        return UV.environment(base, storage: storage, mode: mode)
    }

    /// nil once uv has installed the Python the test scripts ask for; else why not.
    private static let ready = Task<String?, Never> {
        guard let uv = try? await UV.program() else { return "uv isn't installed" }
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/uv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(header(dependencies: "[]", sources: "").utf8).write(to: folder.appending(path: "probe.py"))
        let outcome = await UV.execute(
            uv, ["python", "find", "--script", "probe.py"], in: folder, environment: await environment(.lock),
            timeout: .seconds(300))
        return outcome.succeeded ? nil : "uv couldn't install a Python (offline?): \(outcome.output)"
    }

    static func header(dependencies: String, sources: String) -> String {
        """
        # /// script
        # requires-python = ">=3.12"
        # dependencies = \(dependencies)
        # [tool.uv.sources]
        # \(sources)
        # ///

        """
    }
}

/// A uv extension whose `main.py` answers every run with `body` (Python, the body of
/// `answer(params)`), depending on `tiny`, a wheel in its folder; locked by Wicket's own `uv lock`
/// unless `lock` is false.
private func uvExtension(
    _ body: String, fixture: String? = nil, dependencies: String = #"["tiny"]"#,
    sources: String = #"tiny = { path = "wheels/tiny-1.0-py3-none-any.whl" }"#, lock: Bool = true
) async throws -> TestExtension {
    let ext = try TestExtension(run: #"["uv", "run", "--script", "main.py"]"#, script: "", fixture: fixture)
    let wheels = ext.folder.appending(path: "wheels")
    try FileManager.default.createDirectory(at: wheels, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: try UVTest.wheel, to: wheels.appending(path: "tiny-1.0-py3-none-any.whl"))
    let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
    let script =
        UVTest.header(dependencies: dependencies, sources: sources) + """
            import json, os, sys

            def answer(params):
            \(indented.joined(separator: "\n"))

            for line in sys.stdin:
                message = json.loads(line)
                if "id" in message:
                    result = answer(message["params"])
                    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)

            """
    try Data(script.utf8).write(to: ext.folder.appending(path: "main.py"))
    if lock {
        try await UV.lock(script: "main.py", in: ext.folder, storage: UVTest.storage, timeout: .seconds(120))
    }
    return ext
}

/// A fixture line sending `text` (any string) to the command `go`.
private func sendText(_ id: Int, _ text: String) throws -> String {
    let quoted = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    return
        #"{"send":{"jsonrpc":"2.0","id":\#(id),"method":"run","params":{"command":"go","text":\#(quoted),"revision":\#(id)}}}"#
}

private let uvVariables = [
    "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "UV_LOCKED", "UV_NO_BUILD", "UV_NO_CONFIG", "UV_MANAGED_PYTHON",
    "UV_OFFLINE", "UV_FROZEN",
]

@Test func aUVRunGetsWicketsStorageAndSettings() async throws {
    try await UVTest.require()
    let names = uvVariables.map { "\"\($0)\"" }.joined(separator: ", ")
    let ext = try await uvExtension(
        """
        import tiny
        values = {name: os.environ.get(name) for name in [\(names)]}
        return {"answer": {"title": tiny.greet("uv"), "subtitle": json.dumps(values)}}
        """)
    // A uv setting of the user's never reaches the run.
    let session = try ext.session {
        $0.environment = ["UV_FROZEN": "1", "HOME": NSHomeDirectory()]
        $0.requestTimeout = .seconds(30)
    }
    let result = try await session.run("go", text: "", retry: .never)
    await session.stop()
    guard case .show(.answer(let item)) = result else {
        Issue.record("expected an answer, got \(result)")
        return
    }
    #expect(item.title == "hello uv")
    let values = try JSONDecoder().decode([String: String?].self, from: Data((item.subtitle ?? "").utf8))
    #expect(
        values == [
            "UV_CACHE_DIR": UVTest.storage.cache.path, "UV_PYTHON_INSTALL_DIR": UVTest.storage.python.path,
            "UV_LOCKED": "1", "UV_NO_BUILD": "1", "UV_NO_CONFIG": "1", "UV_MANAGED_PYTHON": "1",
            "UV_OFFLINE": nil,
            "UV_FROZEN": nil,
        ])
}

/// The check installs into a clone of Wicket's cache and replays offline against it; the candidate
/// can write neither Wicket's cache nor its Pythons.
@Test func aUVCheckRunsOfflineOnAClonedCacheItCantEscape() async throws {
    try await UVTest.require()
    let storage = UVTest.storage
    let targets = [storage.cache.path, storage.python.path]
    let request = String(
        decoding: try JSONEncoder().encode([
            "python": storage.python.path, "targets": targets.joined(separator: "\n"),
        ]),
        as: UTF8.self)
    let ext = try await uvExtension(
        """
        import tiny
        request = json.loads(params["text"])
        expected = {
            "UV_CACHE_DIR": os.path.join(os.path.dirname(os.environ["HOME"]), "uv-cache"),
            "UV_PYTHON_INSTALL_DIR": request["python"], "UV_OFFLINE": "1", "UV_LOCKED": "1",
            "UV_NO_BUILD": "1", "UV_NO_CONFIG": "1", "UV_MANAGED_PYTHON": "1",
        }
        wrong = sorted(name for name, value in expected.items() if os.environ.get(name) != value)
        writes = []
        for target in request["targets"].split("\\n"):
            try:
                with open(os.path.join(target, "intruder"), "w") as file:
                    file.write("x")
                writes.append("written")
            except OSError:
                writes.append("denied")
        return {"answer": {"title": ", ".join(wrong) or tiny.greet("check"), "subtitle": ",".join(writes)}}
        """,
        fixture: try sendText(1, request) + "\n"
            + #"{"expect":{"jsonrpc":"2.0","id":1,"result":{"answer":{"title":"hello check","subtitle":"denied,denied"}}}}"#
    )
    let report = await check(ext) { $0.requestTimeout = .seconds(30) }
    #expect(report.passed, "\(report.errors)")
    #expect(
        report.lines.contains { $0.kind == .ok && $0.text.hasPrefix("uv: installed what main.py.lock lists") }
    )
    for target in targets {
        #expect(!FileManager.default.fileExists(atPath: target + "/intruder"))
    }
}

@Test func aMissingLockFailsTheCheckAndTheRun() async throws {
    try await UVTest.require()
    let ext = try await uvExtension(#"return {"close": {}}"#, fixture: send(1), lock: false)
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(
        errors.first?.contains("main.py.lock is missing: run uv lock --script main.py") == true, "\(errors)")

    let session = try ext.session()
    await #expect(throws: HostError.launch(UV.missingLock("main.py"))) {
        try await session.run("go", text: "", retry: .never)
    }
}

@Test func aStaleLockFailsTheCheckWithAHint() async throws {
    try await UVTest.require()
    let ext = try await uvExtension(#"return {"close": {}}"#, fixture: send(1))
    // The dependencies changed after locking.
    let main = ext.folder.appending(path: "main.py")
    let script = try String(contentsOf: main, encoding: .utf8)
    try Data(script.replacingOccurrences(of: #"">=3.12""#, with: #"">=3.13""#).utf8).write(to: main)
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(errors.first?.contains("doesn't match the script's dependencies") == true, "\(errors)")
    #expect(errors.first?.contains("run uv lock --script main.py") == true)
}

/// A lock naming only a source distribution fails: installing it would build it, running its code.
@Test func aDependencyWithoutAWheelFailsTheCheck() async throws {
    try await UVTest.require()
    let ext = try await uvExtension(
        #"return {"close": {}}"#, fixture: send(1), dependencies: #"["tinysdist"]"#,
        sources: #"tinysdist = { path = "pkgs/tinysdist-1.0.tar.gz" }"#, lock: false)
    // `uv lock` with builds off refuses it too, so the lock is written as one made with builds on.
    let sdist = Data("an sdist Wicket must never build".utf8)
    try FileManager.default.createDirectory(
        at: ext.folder.appending(path: "pkgs"), withIntermediateDirectories: true)
    try sdist.write(to: ext.folder.appending(path: "pkgs/tinysdist-1.0.tar.gz"))
    let hash = SHA256.hash(data: sdist).map { String(format: "%02x", $0) }.joined()
    let lock = """
        version = 1
        revision = 3
        requires-python = ">=3.12"

        [manifest]
        requirements = [{ name = "tinysdist", path = "pkgs/tinysdist-1.0.tar.gz" }]

        [[package]]
        name = "tinysdist"
        version = "1.0"
        source = { path = "pkgs/tinysdist-1.0.tar.gz" }
        sdist = { hash = "sha256:\(hash)" }

        """
    try Data(lock.utf8).write(to: ext.folder.appending(path: "main.py.lock"))
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(errors.first?.contains("Wicket installs wheels only") == true, "\(errors)")
}

/// `uv lock` with builds off refuses a dependency that has no wheel, without building it.
@Test func lockingRefusesASourceDistribution() async throws {
    try await UVTest.require()
    let ext = try await uvExtension(
        #"return {"close": {}}"#, dependencies: #"["tinysdist"]"#,
        sources: #"tinysdist = { path = "pkgs/tinysdist-1.0" }"#, lock: false)
    // A project whose build would leave a mark.
    let project = ext.folder.appending(path: "pkgs/tinysdist-1.0")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let mark = ext.folder.appending(path: "built")
    try Data(
        """
        [project]
        name = "tinysdist"
        dynamic = ["version"]
        [build-system]
        requires = []
        build-backend = "backend"
        backend-path = ["."]
        """.utf8
    ).write(to: project.appending(path: "pyproject.toml"))
    try Data(
        "open(\(String(decoding: try JSONEncoder().encode(mark.path), as: UTF8.self)), \"w\").close()\n".utf8
    ).write(to: project.appending(path: "backend.py"))
    await #expect {
        try await UV.lock(script: "main.py", in: ext.folder, storage: UVTest.storage, timeout: .seconds(60))
    } throws: { error in
        String(describing: error).contains("Wicket installs wheels only")
    }
    #expect(!FileManager.default.fileExists(atPath: mark.path))
    #expect(!FileManager.default.fileExists(atPath: ext.folder.appending(path: "main.py.lock").path))
}

@Test func uvxIsRefusedBeforeAnythingRuns() async throws {
    let ext = try TestExtension(run: #"["uvx", "ruff"]"#, script: "", fixture: send(1))
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(errors.first?.contains("uvx and uv tool run fetch a tool without a lock") == true, "\(errors)")
}

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

/// The uv sample passes its check as it is, once its packages are in the storage.
@Test func theUVSamplePasses() async throws {
    try await UVTest.require()
    let sample = repository.appending(path: "Extensions/slugify")
    // As a first run would: the sample's packages from PyPI into the storage, which the check clones.
    let uv = try await UV.program()
    let fetched = await UV.execute(
        uv, ["sync", "--script", "main.py", "--locked"], in: sample, environment: await UVTest.environment(),
        timeout: .seconds(120))
    if !fetched.succeeded { try Test.cancel("couldn't fetch the sample's packages (offline?)") }
    let report = await Checker.check(
        folder: sample, options: checkOptions { $0.requestTimeout = .seconds(30) })
    #expect(report.passed, "\(report.errors)")
}

@Test func pruningRemovesUVsScriptEnvironments() async throws {
    try await UVTest.require()
    let storage = UVStorage(
        root: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/uv-prune-\(UUID().uuidString)"))
    let environment = storage.cache.appending(path: "environments-v2/main-0123456789abcdef")
    try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
    try Data("home = /nowhere\n".utf8).write(to: environment.appending(path: "pyvenv.cfg"))
    await UV.prune(storage)
    #expect(!FileManager.default.fileExists(atPath: environment.path))
}

/// Discovery prunes the uv cache of the extensions that lost a revision, off the main actor.
@MainActor @Test func discoveryPrunesTheUVCacheWithOldRevisions() async throws {
    let ext = try TestExtension(script: answering(#"{"close":{}}"#))
    let storage = UVStorage(root: URL(filePath: "/nonexistent/uv"))
    let extensions = Extensions(
        directory: ext.folder.deletingLastPathComponent(), store: testStore(), approvals: testApprovals(),
        activate: Extensions.currentRevisions
    ) { _ in
        testConfiguration { $0.uv = storage }
    }
    let pruned = Mutex<[UVStorage]>([])
    extensions.pruneUV = { storage in pruned.withLock { $0.append(storage) } }
    try ext.change()
    await extensions.load(changed: [ext.folder.path + "/main.sh"]).value
    #expect(pruned.withLock { $0 }.isEmpty)
    // A second revision: the first, never approved, is pruned.
    try ext.change()
    await extensions.load(changed: [ext.folder.path + "/main.sh"]).value
    let deadline = ContinuousClock.now + .seconds(5)
    while pruned.withLock({ $0 }).isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(pruned.withLock { $0 } == [storage])
    await extensions.shutdown()
}
