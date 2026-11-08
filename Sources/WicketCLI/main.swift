import Foundation
import WicketCore
import WicketHost

// `wicket`: test and configure Wicket extensions from a terminal, the way agents check their work.

let usage = """
    usage: wicket check <folder>
               Review the extension as Wicket does before enabling it, without running it: seal
               the folder, validate the manifest and find the program it runs. Exits 1 if anything
               fails.
           wicket run <folder> <command> [text] [--args <json-object>]
               Run one command as Wicket does and print the response as the extension wrote it.
               Exits 1 unless it is a valid result, markup included. Runs the folder itself, with
               your environment and real secrets.
           wicket log <extension-id>
               Print the extension's recent runs in Wicket, oldest first: time, command, outcome
               (ok, error, rejected, refused, crashed, timeout), duration and revision, and for a
               failed run its message, the text and args it was sent and the end of its stderr.
           wicket secret set <extension-id> <NAME>
               Store a secret declared in wicket.json in the Keychain; the value is read from stdin.
           wicket agent status
               Show whether Claude Code and Codex are ready to answer.

    For run, secrets are read from environment variables of the same name first, then from the
    Keychain.
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

/// `wicket run`: the developer's own run, with their environment and real secrets.
func configuration(for id: String) -> RunConfiguration {
    RunConfiguration(dataDirectory: ExtensionPaths.data(for: id), version: appVersion()) { name in
        ProcessInfo.processInfo.environment[name] ?? Keychain.secret(name, extension: id)
    }
}

func folder(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .isDirectory, relativeTo: .currentDirectory()).standardizedFileURL
}

func check(_ path: String) async -> Never {
    let report = await Checker.check(folder: folder(path))
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
    guard let declared = manifest.command(command) else {
        let ids = manifest.commands.map(\.id).joined(separator: ", ")
        fail("error: wicket.json declares no command \"\(command)\"; its commands are \(ids)", status: 2)
    }
    // Through the same invocation policy as a row, a keyword or a run action in the app.
    let invocation = CommandRun(
        RegisteredCommand(extension: manifest.id, command: declared, icon: nil), .invoked,
        text: arguments.count == 3 ? arguments[2] : "", args: args
    ).invocation
    let run = await ExtensionProcess.run(
        Request(command: command, text: invocation.text, args: invocation.args), manifest: manifest,
        folder: folder, configuration: configuration(for: manifest.id))
    if let output = run.output { print(output) }
    let stderr = run.stderr.split(separator: "\n").suffix(20)
    let tail =
        stderr.isEmpty ? "" : "\nthe last stderr lines were:\n    " + stderr.joined(separator: "\n    ")
    switch run.result {
    case .success(let result):
        let problems = result.markupProblems
        guard !problems.isEmpty else { exit(0) }
        fail(problems.map { "error: \($0)" }.joined(separator: "\n"))
    case .failure(let error as ExtensionError):
        fail("error: the extension answered with an error: \(error.message)\(tail)")
    case .failure(let error):
        fail("error: \(error)\(tail)")
    }
}

func log(_ id: String) async -> Never {
    let history = ExtensionHistory(root: ExtensionPaths.history)
    guard let folder = history.folder(of: id) else {
        fail("error: \"\(id)\" is not an extension id", status: 2)
    }
    let runs = await history.runs(of: id)
    guard !runs.isEmpty else {
        print("no runs of \(id) recorded in \(folder.path)")
        exit(0)
    }
    print(ExtensionHistory.text(runs))
    exit(0)
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

func agentStatus() async -> Never {
    for provider in AgentProvider.allCases { print(await Agent.status(of: provider)) }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "check" where arguments.count == 2: await check(arguments[1])
case "run": await run(Array(arguments.dropFirst()))
case "log" where arguments.count == 2: await log(arguments[1])
case "secret" where arguments.count == 4 && arguments[1] == "set":
    setSecret(id: arguments[2], name: arguments[3])
case "agent" where arguments.count == 2 && arguments[1] == "status": await agentStatus()
case "help", "-h", "--help": print(usage)
default: fail(usage, status: 2)
}
