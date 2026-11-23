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
    "main must be synchronous; wicket.fetch returns directly"
  ),
  (
    "function main() { return Promise.resolve({body: 'bad'}); }",
    "main must be synchronous; wicket.fetch returns directly"
  ),
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

private func serveJavaScriptHTTP(in folder: URL) async throws -> (Process, String) {
  try await serveHTTPFixture(
    in: folder,
    source: """
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from time import sleep

      class Handler(BaseHTTPRequestHandler):
          def reply(self, status, body=b"", headers={}):
              self.send_response(status)
              self.send_header("Content-Length", str(len(body)))
              for key, value in headers.items():
                  self.send_header(key, value)
              self.end_headers()
              self.wfile.write(body)
          def do_GET(self):
              with open("requests", "a") as log:
                  print(self.path, file=log)
              if self.path == "/timeout":
                  sleep(30)
              elif self.path == "/disconnect":
                  self.close_connection = True
              elif self.path == "/overflow":
                  self.reply(200, b"x" * 1048577)
              elif self.path.startswith("/redirect/"):
                  remaining = int(self.path.split("/")[-1])
                  if remaining:
                      self.reply(302, headers={"Location": f"/redirect/{remaining - 1}"})
                  else:
                      self.reply(200, b"redirected")
              elif self.path == "/bad-redirect":
                  self.reply(302, headers={"Location": "file:///dev/null"})
              elif self.path == "/get":
                  self.reply(200, "café".encode(), {"X-Fixture": "present"})
              else:
                  self.reply(404, b"missing")
          def do_POST(self):
              body = self.rfile.read(int(self.headers["Content-Length"]))
              self.reply(201, body, {"X-Fixture": self.headers["X-Fixture"]})
          def log_message(self, *args):
              pass

      with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
          print(server.server_port)
          server.serve_forever()
      """)
}

// Each case launches Wicket and some start a fixture server. Keep those launches out of each other’s way.
@Suite(.serialized) struct JavaScriptHostTests {
  @Test func javaScriptFetchReturnsStatusHeadersAndBody() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let (server, base) = try await serveJavaScriptHTTP(in: root)
    defer { server.terminate() }
    _ = try installScript(
      """
      function main({ input }) {
        const get = wicket.fetch(input + "/get");
        const post = wicket.fetch(input + "/post", {
          method: "POST", headers: {"X-Fixture": "from JavaScript"}, body: "café"
        });
        const missing = wicket.fetch(input + "/not-found");
        return {body: [get.status, get.headers["x-fixture"], get.body,
          post.status, post.headers["x-fixture"], post.body, missing.status, missing.body].join("\\n")};
      }
      """, in: root)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted", "--input", base])
    #expect(status == 0)
    #expect(view["body"].string == "200\npresent\ncafé\n201\nfrom JavaScript\ncafé\n404\nmissing")
  }

  @Test func javaScriptFetchThrowsOnTimeoutTransportErrorAndOverflow() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let (server, base) = try await serveJavaScriptHTTP(in: root)
    defer { server.terminate() }
    _ = try installScript(
      #"""
      function main({input}) {
        const messages = [];
        for (const path of ["/timeout", "/disconnect", "/overflow"]) {
          try { wicket.fetch(input + path, {timeoutMs: path === "/timeout" ? 50 : 2000}); }
          catch (error) { if (error instanceof Error) messages.push(error.message); }
        }
        return {body: messages.join("\n")};
      }
      """#, in: root)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted", "--input", base])
    let messages = try #require(view["body"].string).components(separatedBy: "\n")
    #expect(status == 0)
    #expect(messages.count == 3)
    #expect(messages.first == "wicket.fetch: timed out")
    #expect(messages.dropFirst().first?.hasPrefix("wicket.fetch: ") == true)
    #expect(messages.last == "wicket.fetch: response body exceeds 1 MiB")
  }

  @Test func javaScriptFetchAllowsFiveHTTPRedirects() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let (server, base) = try await serveJavaScriptHTTP(in: root)
    defer { server.terminate() }
    _ = try installScript(
      #"""
      function main({input}) {
        return {body: wicket.fetch(input).body};
      }
      """#, in: root)
    let args = ["--extension", "javascript", "--submitted", "--input"]
    let (success, view) = try await cli(root, args + [base + "/redirect/5"])
    #expect(success == 0 && view["body"].string == "redirected")
    let (limit, limitRepair) = try await cli(root, args + [base + "/redirect/6"])
    #expect(limit == 1 && limitRepair["error"].string?.contains("wicket.fetch: too many redirects") == true)
    let (scheme, schemeRepair) = try await cli(root, args + [base + "/bad-redirect"])
    #expect(scheme == 1 && schemeRepair["error"].string?.contains("wicket.fetch:") == true)
  }

  @Test func javaScriptRootMatchesBlockIOEvenBeforeMainAndAfterEditingTheRequest() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let (server, base) = try await serveJavaScriptHTTP(in: root)
    defer { server.terminate() }
    let folder = try installScript(
      """
      const messages = [];
      function attemptIO() {
        for (const call of [() => wicket.fetch("\(base)/get"), () => wicket.run(["touch", "started"])]) {
          try { call(); } catch (error) { if (error instanceof Error) messages.push(error.message); }
        }
      }
      attemptIO();
      function main(request) {
        request.rootMatch = false;
        request.submitted = true;
        attemptIO();
        return {items: [{id: "result", title: messages.join("|"), actions: []}]};
      }
      """, in: root, manifest: ["match": "^jstest$"])
    try saveProviders([.init("extension:javascript")], in: root)
    let (status, query) = try await cli(root, ["--query", "jstest"])
    let result = try #require(query["items"].array.first)
    let messages = try #require(result["row"]["title"].string).components(separatedBy: "|")
    let expected = [
      "wicket.fetch: unavailable during a root match", "wicket.run: unavailable during a root match",
    ]
    #expect(status == 0 && messages == expected + expected)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "requests").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
  }

  @Test func javaScriptRunUsesLiteralArgumentsAndReturnsBothStreamsAndExitStatus() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let folder = try installScript(
      #"""
      function main() {
        const input = "café\n".repeat(15000);
        const cat = wicket.run(["cat"], {input});
        const literal = wicket.run(["printf", "%s", "$(touch started); * \"'"]);
        const program = wicket.run(["./fixture"]);
        const terminated = wicket.run(["/bin/sh", "-c", "kill -TERM $$"]);
        return {body: JSON.stringify([cat.stdout === input, cat.status, cat.signal,
          literal.stdout, program.stdout, program.stderr, program.status, program.signal,
          terminated.status, terminated.signal])};
      }
      """#, in: root)
    let program = folder.appending(path: "fixture")
    try Data(
      #"""
      #!/bin/sh
      if [ -d "$WICKET_DATA_DIR" ] && [ -f main.js ]; then printf 'in extension'; fi
      printf 'error' >&2
      exit 7
      """#.utf8
    ).write(to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted"])
    #expect(status == 0)
    #expect(
      view["body"].string == #"[true,0,null,"$(touch started); * \"'","in extension","error",7,null,null,15]"#
    )
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "started").path))
  }

  @Test func javaScriptRunThrowsOnTimeoutAndCombinedOutputOverflow() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    _ = try installScript(
      #"""
      function main() {
        const failures = [];
        for (const call of [
          () => wicket.run(["/bin/sleep", "30"], {input: "x".repeat(100000), timeoutMs: 50}),
          () => wicket.run(["/bin/sh", "-c", "printf 12345; printf 67890 >&2"], {maxBytes: 9}),
          () => wicket.run(["/usr/bin/yes"]),
          () => wicket.run(["/bin/echo"], {maxBytes: 1048577}),
          () => wicket.run(["/bin/echo"], {timeoutMs: 5001}),
        ]) {
          try { call(); } catch (error) { if (error instanceof Error) failures.push(error.message); }
        }
        return {body: failures.join("\n")};
      }
      """#, in: root)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted"])
    #expect(status == 0)
    #expect(
      view["body"].string?.components(separatedBy: "\n") == [
        "wicket.run: timed out", "wicket.run: combined output exceeds 9 bytes",
        "wicket.run: combined output exceeds 262144 bytes", "wicket.run: invalid maxBytes",
        "wicket.run: invalid timeoutMs",
      ])
  }

  @Test(arguments: ["fetch", "run"])
  func javaScriptHostCallsUseTheRemainingRequestBudget(operation: String) async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let (server, base) = try await serveJavaScriptHTTP(in: root)
    defer { server.terminate() }
    let call =
      operation == "fetch"
      ? "wicket.fetch(input + '/timeout', {timeoutMs: 5000})"
      : "wicket.run(['/bin/sleep', '30'], {timeoutMs: 5000})"
    _ = try installScript(
      """
      function main({input}) {
        wicket.run(["/bin/sleep", "4"], {timeoutMs: 5000});
        wicket.run(["/bin/sleep", "3"], {timeoutMs: 5000});
        try { \(call); } catch (error) { return {body: error.message}; }
      }
      """, in: root)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted", "--input", base])
    #expect(status == 0 && view["body"].string == "wicket.\(operation): timed out", "\(view)")
  }

  @Test func javaScriptRunLeavesDescendantCleanupToTheRequest() async throws {
    let root = try scratch()
    defer { removeHeadlessScratch(root) }
    let folder = try installScript(
      #"""
      function main() {
        try {
          wicket.run(["/bin/sh", "-c", "/bin/sleep 30 & echo $! > descendant; wait"], {timeoutMs: 500});
        } catch (error) {
          return {body: error.message};
        }
      }
      """#, in: root)
    let (status, view) = try await cli(root, ["--extension", "javascript", "--submitted"])
    #expect(status == 0 && view["body"].string == "wicket.run: timed out")
    let pid = try #require(
      Int32(
        String(contentsOf: folder.appending(path: "descendant"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(!isRunning(pid))
  }
}
