import Foundation
import WicketCore
import WicketHost

// `wicket`: test and configure Wicket extensions from a terminal, the way agents check their work.

let usage = """
    usage: wicket check <folder>
               Validate the manifest, replay every session.jsonl fixture against the extension and
               check each response against the protocol. Exits 1 if anything fails.
           wicket run <folder> <command> [text] [--args <json-object>]
               Send one run request and print the response line as the extension wrote it.
           wicket secret set <extension-id> <NAME>
               Store a secret declared in wicket.json in the Keychain; the value is read from stdin.

    Secrets are read from environment variables of the same name first, then from the Keychain.
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

/// The version of the Wicket.app this tool is bundled in (Contents/Helpers/wicket), or "dev".
func appVersion() -> String {
    let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "dev"
}

func configuration(for id: String, dataDirectory: URL) -> SessionConfiguration {
    var configuration = SessionConfiguration(dataDirectory: dataDirectory, version: appVersion()) { name in
        ProcessInfo.processInfo.environment[name] ?? Keychain.secret(name, extension: id)
    }
    configuration.idleTimeout = nil
    return configuration
}

func folder(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .isDirectory, relativeTo: .currentDirectory()).standardizedFileURL
}

func check(_ path: String) async -> Never {
    let folder = folder(path)
    let id = (try? Manifest.load(from: folder))?.id ?? "check"
    // A fresh data folder, so fixtures don't depend on state from earlier runs.
    let data = FileManager.default.temporaryDirectory.appending(path: "wicket-check-\(UUID().uuidString)")
    let report = await Checker.check(folder, configuration: configuration(for: id, dataDirectory: data))
    try? FileManager.default.removeItem(at: data)
    for line in report.lines { print("\(line.kind.rawValue): \(line.text)") }
    let errors = report.errors.count
    print(report.passed ? "check passed" : "check failed: \(errors) error\(errors == 1 ? "" : "s")")
    exit(report.passed ? 0 : 1)
}

func run(_ arguments: [String]) async -> Never {
    var arguments = arguments
    var args: [String: JSONValue]?
    if let index = arguments.firstIndex(of: "--args") {
        guard index + 1 < arguments.count,
            case .object(let object)? = try? JSONDecoder().decode(
                JSONValue.self, from: Data(arguments[index + 1].utf8))
        else { fail("--args needs a JSON object, like --args '{\"id\": 12}'", status: 2) }
        args = object
        arguments.removeSubrange(index...index + 1)
    }
    guard arguments.count == 2 || arguments.count == 3 else { fail(usage, status: 2) }
    let folder = folder(arguments[0])
    let manifest: Manifest
    do {
        manifest = try Manifest.load(from: folder)
    } catch {
        fail("error: \(error)")
    }
    let command = arguments[1]
    guard manifest.command(command) != nil else {
        let ids = manifest.commands.map(\.id).joined(separator: ", ")
        fail("error: wicket.json declares no command \"\(command)\"; its commands are \(ids)", status: 2)
    }
    let session = ExtensionSession(
        manifest: manifest, folder: folder,
        configuration: configuration(for: manifest.id, dataDirectory: ExtensionPaths.data(for: manifest.id)))
    let params = RunParams(
        command: command, text: arguments.count == 3 ? arguments[2] : "", revision: 1, args: args)
    let result: Result<Reply, any Error>
    do {
        result = .success(try await session.submit(.number(1), params).value)
    } catch {
        result = .failure(error)
    }
    for warning in await session.warnings {
        FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
    }
    for issue in await session.issues { FileHandle.standardError.write(Data("error: \(issue)\n".utf8)) }
    _ = await session.shutdown()
    switch result {
    case .success(let reply):
        print(reply.line)
        exit(0)
    case .failure(let error):
        let stderr = session.stderrTail.split(separator: "\n").suffix(20)
        let tail =
            stderr.isEmpty ? "" : "\nthe last stderr lines were:\n    " + stderr.joined(separator: "\n    ")
        fail("error: \(error)\(tail)")
    }
}

func setSecret(id: String, name: String) -> Never {
    guard Manifest.isSlug(id) else { fail("error: \"\(id)\" is not an extension id", status: 2) }
    var value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    if value.hasSuffix("\n") { value.removeLast() }
    guard !value.isEmpty else {
        fail("error: no value on stdin; pipe it in, like: pbpaste | wicket secret set \(id) \(name)")
    }
    do {
        try Keychain.setSecret(value, name: name, extension: id)
    } catch {
        fail("error: \(error)")
    }
    print("stored \(name) for \(id)")
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "check" where arguments.count == 2: await check(arguments[1])
case "run": await run(Array(arguments.dropFirst()))
case "secret" where arguments.count == 4 && arguments[1] == "set":
    setSecret(id: arguments[2], name: arguments[3])
case "help", "-h", "--help": print(usage)
default: fail(usage, status: 2)
}
