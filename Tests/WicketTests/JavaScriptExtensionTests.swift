import Foundation
import Testing

@testable import WicketApp

private func installScript(
  _ source: String, in root: URL, name: String = "javascript", manifest: [String: Any] = [:]
) throws -> URL {
  let folder = root.appending(path: "extensions/" + name)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let fields: [String: Any] = ["contract": 2, "name": name, "command": ["wicket-js", "main.js"]]
  try JSONSerialization.data(withJSONObject: fields.merging(manifest) { _, value in value })
    .write(to: folder.appending(path: "wicket.json"))
  try Data(source.utf8).write(to: folder.appending(path: "main.js"))
  return folder
}

@Test func javaScriptReceivesTheWireRequestAndReturnsAView() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try installScript(
    #"""
    function main(request) {
      const { input, fields, submitted, action, locale, settings } = request;
      if (!submitted || action !== "confirm" || typeof locale.decimal !== "string")
        throw new Error("Unexpected request");
      return {
        items: [{ id: "result", title: input + fields.suffix + settings.punctuation,
                  actions: [{ type: "copy", text: input }] }]
      };
    }
    """#, in: root,
    manifest: [
      "settings": [["name": "punctuation", "type": "text", "description": "Punctuation", "default": "!"]]
    ])
  let (status, view) = try await cli(
    root,
    [
      "--extension", "javascript", "--input", "Wicket", "--fields", #"{"suffix":" JS"}"#,
      "--submitted", "--action", "confirm",
    ])
  #expect(status == 0)
  let row = try #require(view["items"].array.first)
  #expect(row["title"].string == "Wicket JS!")
  #expect(row["actions"].array.first?["text"].string == "Wicket")
}

@Test func javaScriptReadsAnEditedSymlinkedExtensionAndCanReturnMarkdownOrSilence() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let config = root.appending(path: "config")
  let folder = try installScript(
    "const main = () => '# Markdown';", in: root, manifest: ["submit": true, "hidden": true])
  let extensions = config.appending(path: "extensions")
  try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: extensions.appending(path: "javascript"), withDestinationURL: folder)
  let args = ["--extension", "javascript", "--submitted"]
  let (shown, view) = try await cli(config, args)
  #expect(shown == 0 && view["body"].string == "# Markdown")

  try Data("function main() {}".utf8).write(to: folder.appending(path: "main.js"), options: .atomic)
  let (silent, empty) = try await cli(config, args)
  #expect(silent == 0 && empty == .object([:]))
}

@Test func javaScriptStoragePersistsAcrossRequestsAndIsScopedToTheExtension() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let source = #"""
    function main(request) {
      const previous = wicket.read("state.json");
      if (request.submitted)
        wicket.write("state.json", JSON.stringify(request.input));
      return { body: previous === null ? "missing" : JSON.parse(previous) };
    }
    """#
  _ = try installScript(source, in: root)
  _ = try installScript(source, in: root, name: "peer")
  let (initial, missing) = try await cli(
    root, ["--extension", "javascript", "--input", "café 🍰", "--submitted"])
  #expect(initial == 0 && missing["body"].string == "missing")
  let (second, previous) = try await cli(
    root, ["--extension", "javascript", "--input", "updated", "--submitted"])
  #expect(second == 0 && previous["body"].string == "café 🍰")
  let (third, updated) = try await cli(root, ["--extension", "javascript"])
  #expect(third == 0 && updated["body"].string == "updated")
  let (peer, independent) = try await cli(root, ["--extension", "peer"])
  #expect(peer == 0 && independent["body"].string == "missing")
}

@Test func javaScriptStorageRejectsLinksAndLimitsAndThrowsCatchableErrors() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try installScript(
    #"""
    function main(request) {
      const failures = [];
      for (const operation of [
        () => wicket.read("../state"),
        () => wicket.read("link"),
        () => wicket.write("link", "new"),
        () => wicket.read("oversized"),
        () => wicket.write("state", "é".repeat(524289)),
      ]) {
        try { operation(); } catch (error) { failures.push(error instanceof Error ? error.message : "not an Error"); }
      }
      return { body: failures.join("\n") };
    }
    """#, in: root)
  let base = Edition.release.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": root.path])
  let data = ExtensionRunner(dataDirectory: base).dataDirectory(for: "extension:javascript")
  try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
  let outside = root.appending(path: "state")
  try Data("original".utf8).write(to: outside)
  try FileManager.default.createSymbolicLink(at: data.appending(path: "link"), withDestinationURL: outside)
  try Data(repeating: 0, count: 1_048_577).write(to: data.appending(path: "oversized"))
  let (status, view) = try await cli(root, ["--extension", "javascript"])
  let messages = view["body"].string?.components(separatedBy: "\n") ?? []
  #expect(status == 0 && messages.count == 5)
  #expect(
    messages.map { String($0.prefix { $0 != ":" }) } == [
      "wicket.read", "wicket.read", "wicket.write", "wicket.read", "wicket.write",
    ])
  #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
}

@Test(arguments: [
  (
    "async function main() { return {body: 'bad'}; }",
    "main must be synchronous"
  ),
  ("function main() { return Promise.resolve({body: 'bad'}); }", "main must be synchronous"),
  ("function main() { const view = {}; view.loop = view; return view; }", "cyclic"),
  ("function main() { return null; }", "main must return"),
  ("const count = 42;", "define a top-level main(request)"),
])
func javaScriptReportsInvalidMainAndReturnValues(source: String, diagnostic: String) async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try installScript(source, in: root)
  let (status, view) = try await cli(root, ["--extension", "javascript"])
  #expect(status == 1)
  #expect(view["error"].string?.localizedCaseInsensitiveContains(diagnostic) == true)
}

@Test func javaScriptRequiresOneScriptInsideTheExtensionFolder() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let source = "function main() { return '# OK'; }"
  try Data(source.utf8).write(to: root.appending(path: "outside.js"))
  let link = try installScript(
    source, in: root, name: "link", manifest: ["command": ["wicket-js", "link.js"]])
  try FileManager.default.createSymbolicLink(
    at: link.appending(path: "link.js"), withDestinationURL: root.appending(path: "outside.js"))
  for (name, argv, diagnostic) in [
    ("no-script", ["wicket-js"], "expected one relative script path"),
    ("missing", ["wicket-js", "missing.js"], "missing.js"),
    ("traversal", ["wicket-js", "../../outside.js"], "expected a relative script path"),
    ("link", ["wicket-js", "link.js"], "script must be inside the extension folder"),
  ] {
    if name != "link" { _ = try installScript(source, in: root, name: name, manifest: ["command": argv]) }
    let (status, view) = try await cli(root, ["--extension", name])
    #expect(status == 1 && view["error"].string?.contains(diagnostic) == true)
  }
}

@Test func javaScriptSendsConsoleToStderrAndReportsTheThrowLocation() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try installScript(
    #"""
    console.log("top-level", 42);
    function main(request) {
      console.error("diagnostic", request.input);
      if (request.input === "fail") throw new Error("test exception");
      return { body: "Clean view" };
    }
    """#, in: root)
  let (status, view) = try await cli(root, ["--extension", "javascript"])
  #expect(status == 0 && view["body"].string == "Clean view")
  let (failed, repair) = try await cli(root, ["--extension", "javascript", "--input", "fail"])
  let diagnostic = try #require(repair["error"].string)
  #expect(failed == 1)
  #expect(diagnostic.contains("top-level 42") && diagnostic.contains("diagnostic fail"))
  #expect(diagnostic.contains("main.js: line 4: Error: test exception"))
}

@Test func javaScriptRunsOnARootMatch() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try installScript(
    #"""
    function main(request) {
      if (!request.rootMatch || request.submitted) throw new Error("Expected a root match");
      return { items: [{ id: "result", title: "Matched " + request.input, actions: [] }] };
    }
    """#, in: root, manifest: ["match": "^jstest [0-9]+$"])
  try saveProviders([.init("extension:javascript")], in: root)
  let (status, query) = try await cli(root, ["--query", "jstest 42"])
  #expect(status == 0)
  let result = try #require(query["items"].array.first)
  #expect(result["provider"].string == "extension:javascript")
  #expect(result["row"]["title"].string == "Matched jstest 42")
}
