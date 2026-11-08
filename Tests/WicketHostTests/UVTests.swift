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
            uv, ["python", "find", "--script", "probe.py"], in: folder,
            environment: await environment(.maintenance),
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
/// `answer(params)`), depending on `tiny`, a wheel in its folder; locked with `uv lock --script`
/// (wheels only, as every uv run here) unless `lock` is false.
private func uvExtension(
    _ body: String, dependencies: String = #"["tiny"]"#,
    sources: String = #"tiny = { path = "wheels/tiny-1.0-py3-none-any.whl" }"#, lock: Bool = true
) async throws -> TestExtension {
    let ext = try TestExtension(run: #"["uv", "run", "--script", "main.py"]"#, script: "")
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
        let locked = await UV.execute(
            try await UV.program(), ["lock", "--script", "main.py"], in: ext.folder,
            environment: await UVTest.environment(.maintenance), timeout: .seconds(120))
        try #require(locked.succeeded, "uv lock failed: \(locked.output)")
    }
    return ext
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
    let session = try ext.session {
        $0.requestTimeout = .seconds(30)
    }
    let result = try await session.run("go", text: "", retry: .never)
    await session.stop()
    guard case .show(.answer(let item), _) = result else {
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

@Test func aMissingLockFailsTheRun() async throws {
    try await UVTest.require()
    let ext = try await uvExtension(#"return {"close": {}}"#, lock: false)

    let session = try ext.session()
    await #expect(throws: HostError.launch(UV.missingLock("main.py"))) {
        try await session.run("go", text: "", retry: .never)
    }
}

@Test func uvxIsRefusedBeforeAnythingRuns() async throws {
    let ext = try TestExtension(run: #"["uvx", "ruff"]"#, script: "")
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(errors.first?.contains("uvx and uv tool run fetch a tool without a lock") == true, "\(errors)")
}

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

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
