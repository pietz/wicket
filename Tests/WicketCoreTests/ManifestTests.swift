import Foundation
import Testing

@testable import WicketCore

private let valid = #"""
    {
      "$schema": "../extension.schema.json",
      "protocol": 1, "id": "github-prs", "name": "GitHub", "version": "1.2.3",
      "icon": {"symbol": {"name": "cloud"}},
      "run": ["python3", "main.py"], "capabilities": ["network"],
      "secrets": [{"name": "GITHUB_TOKEN", "title": "GitHub token"}],
      "commands": [
        {"id": "prs", "title": "Pull Requests", "keyword": "pr", "mode": "live", "placeholder": "Filter"},
        {"id": "convert", "title": "Convert"},
        {"id": "done", "title": "Done", "hidden": true}
      ]
    }
    """#

private func manifest(_ json: String) throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
}

/// `valid` with one replacement applied, and the summary of the error it causes.
private func problem(_ old: String, _ new: String) -> String? {
    #expect(valid.contains(old), "\(old)")
    do {
        _ = try manifest(valid.replacingOccurrences(of: old, with: new))
        return nil
    } catch let error as DecodingError {
        return error.summary
    } catch {
        return "\(error)"
    }
}

@Test func decodesAValidManifest() throws {
    let manifest = try manifest(valid)
    #expect(manifest.id == "github-prs")
    #expect(manifest.secrets.map(\.name) == ["GITHUB_TOKEN"])
    #expect(manifest.capabilities == [.network])
    #expect(manifest.commands.map(\.mode) == [.live, .once, .once])
    #expect(manifest.command("done")?.hidden == true)
    #expect(manifest.command("prs")?.keyword == "pr")
    #expect(manifest.commands.allSatisfy { $0.search.isEmpty })
}

@Test func decodesSearchTermsWithinTheLimits() throws {
    let terms = Array(repeating: String(repeating: "é", count: 128), count: 16)
    let data = try JSONEncoder().encode(terms)
    let json = valid.replacingOccurrences(
        of: #""title": "Done""#,
        with: #""title": "Done", "search": \#(String(decoding: data, as: UTF8.self))"#)
    #expect(try manifest(json).command("done")?.search == terms)
}

@Test(arguments: [
    (#""wireless""#, "commands[0].search"),
    ("null", "commands[0].search"),
    (#"["wireless", 7]"#, "commands[0].search[1]"),
    (#"[""]"#, "each search term must contain non-whitespace text"),
    (#"["  \n\t "]"#, "each search term must contain non-whitespace text"),
    (#"["\#(String(repeating: "a", count: 129))"]"#, "at most 128 characters"),
    (#"["\#(String(repeating: "e\u{301}", count: 65))"]"#, "at most 128 characters"),
    ("[" + Array(repeating: #""term""#, count: 17).joined(separator: ",") + "]", "at most 16 search terms"),
])
func rejectsInvalidSearchTerms(value: String, expected: String) {
    let summary = problem(#""keyword": "pr""#, #""keyword": "pr", "search": \#(value)"#)
    #expect(summary?.contains(expected) == true, "\(summary ?? "accepted")")
}

@Test(arguments: [
    (#""protocol": 1"#, #""protocol": 2"#, "this Wicket speaks protocol 1"),
    (#""id": "github-prs""#, #""id": "GitHub""#, "is not a valid id"),
    (#""id": "github-prs""#, #""id": "a--b""#, "is not a valid id"),
    (#""name": "GitHub""#, #""name": """#, "name: must not be empty"),
    (#""version": "1.2.3""#, #""version": "1.2""#, "must be major.minor.patch"),
    (#""run": ["python3", "main.py"]"#, #""run": []"#, "must name a program"),
    (#""capabilities": ["network"]"#, #""capabilities": ["internet"]"#, "must be network, clipboard"),
    (#""capabilities": ["network"]"#, #""capabilities": ["network", "network"]"#, "twice"),
    (#""GITHUB_TOKEN""#, #""github_token""#, "must be an environment variable name"),
    (#""GITHUB_TOKEN""#, #""WICKET_TOKEN""#, "reserved"),
    (#""GITHUB_TOKEN""#, #""PATH""#, "reserved"),
    (#""mode": "live""#, #""mode": "stream""#, "must be once or live"),
    (#""keyword": "pr""#, #""keyword": "p r""#, "must be one word"),
    (#""hidden": true"#, #""hidden": true, "pattern": "x""#, "commands[2].pattern: unknown field"),
    (#""id": "done""#, #""id": "prs""#, "two commands with the id \"prs\""),
    (#""title": "Done""#, #""title": "Done", "subtitel": "x""#, #"commands[2].subtitel: unknown field"#),
    (#""protocol": 1,"#, #""protocol": 1, "author": "me","#, #"author: unknown field"#),
    (#""run": ["python3", "main.py"],"#, "", #"run: missing required field"#),
    (#""run": ["python3", "main.py"]"#, #""run": ["uvx", "ruff"]"#, "vendor Python packages"),
    (#""run": ["python3", "main.py"]"#, #""run": ["/opt/homebrew/bin/uv", "run", "m.py"]"#, "doesn't run uv"),
])
func rejectsInvalidManifests(old: String, new: String, expected: String) {
    let summary = problem(old, new)
    #expect(summary?.contains(expected) == true, "\(summary ?? "accepted")")
}

@Test func loadNamesTheFile() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: ManifestError.self) { try Manifest.load(from: folder) }
    try Data(#"{"protocol":1}"#.utf8).write(to: folder.appending(path: "wicket.json"))
    #expect(throws: ManifestError(description: #"wicket.json: id: missing required field "id""#)) {
        try Manifest.load(from: folder)
    }
}

@Test func theExamplesAreValid() throws {
    let examples = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/examples")
    for name in ["unicode", "week-number"] {
        #expect(try Manifest.load(from: examples.appending(path: name)).id == name)
    }
}
