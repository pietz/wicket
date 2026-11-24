import Foundation
import Testing

@testable import WicketApp

private let deniedPermissions = Permissions(
  status: { $0 == .accessibility ? .denied : .askable },
  request: { _ in Issue.record("Diagnostics asked for a permission") }, microphone: { .granted })

@MainActor @Test func diagnosticsDescribeTheCatalogAndHotkeysWithoutRunningExtensions() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundledBase = root.appending(path: "bundle")
  let bundled = bundledBase.appending(path: "extensions")
  let script = "touch ran; exit 1"
  for name in ["built-in", "override", "broken", "units"] {
    _ = try extensionFolder(bundledBase, name: name, script: script)
  }
  let local = try extensionFolder(root, name: "local", script: script, fields: ["permissions": ["calendar"]])
  let override = try extensionFolder(root, name: "override", script: script)
  let broken = try extensionFolder(root, name: "broken", script: script, fields: ["contract": 1])
  _ = try extensionFolder(root, name: "stranded", script: script, fields: ["contract": 1])
  let retired = root.appending(path: "extensions/units")
  try FileManager.default.copyItem(at: fixtureURL("retired-units"), to: retired)
  try Data("broken user items".utf8).write(to: broken.appending(path: "user.json"))

  var config = Configuration()
  config.resultsOnlyWhenTyping = true
  config.providers = [.init("extension:built-in", enabled: false)]
  config.hotkeys = try [
    ("ctrl+1", "wicket://override?input=private-query"),
    ("ctrl+2", "wicket://built-in"),
    ("ctrl+3", "wicket://nonexistent"),
    ("ctrl+4", "wicket://override?item=nonexistent"),
    ("ctrl+5", "wicket://local"),
    ("ctrl+1", "wicket://settings"),
    (config.hotkey.description, "wicket://clipboard"),
    ("ctrl+6", "wicket://units"),
  ].map {
    .init(keys: try Shortcut($0.0), target: try #require(HotkeyTarget($0.1)))
  }
  try config.save(at: root.appending(path: "config.json"))
  let env = ["WICKET_CONFIG_DIR": root.path, Diagnostics.agentEnvironmentKey: "1"]
  let url = RuntimeRecord.url(beside: AgentLog.standard(environment: env))
  let recorder = RuntimeRecorder(url: url)
  let launcher = HotKeyRegistration { _ in NSObject() }
  let commandKeys = CommandHotKeys { keys, _ in keys == config.hotkeys.last?.keys ? nil : NSObject() }
  let launcherProblem = launcher.apply(config.hotkey)
  _ = commandKeys.apply(config.hotkeys, launcher: launcher.inEffect)
  recorder.observePermissions(deniedPermissions)
  recorder.register(
    .init(launcher: launcher.snapshot(config.hotkey, problem: launcherProblem), bindings: commandKeys.latest))
  await recorder.finish()

  let data = try await Diagnostics.report(
    folder: root, bundled: bundled, permissions: deniedPermissions, environment: env)
  let report = try JSONDecoder().decode(JSONValue.self, from: data)
  let entries = Dictionary(
    uniqueKeysWithValues: try report["extensions"].array.map {
      (try #require($0["id"].string), $0)
    })
  func pointsTo(_ id: String, _ key: String, _ folder: URL) throws -> Bool {
    let path = try #require(entries[id]?[key].string)
    return Edition.sameFolder(URL(fileURLWithPath: path), folder)
  }
  #expect(entries["extension:built-in"]?["source"] == .string("bundled"))
  #expect(entries["extension:built-in"]?["enabled"] == .bool(false))
  #expect(entries["extension:local"]?["source"] == .string("local"))
  #expect(try pointsTo("extension:local", "activeFolder", local))
  #expect(entries["extension:local"]?["missingPermissions"] == .array([.string("calendar")]))
  #expect(entries["extension:override"]?["source"] == .string("local overriding bundled"))
  #expect(try pointsTo("extension:override", "activeFolder", override))
  #expect(entries["extension:units"]?["source"] == .string("retired local copy ignored"))
  #expect(try pointsTo("extension:units", "localFolder", retired))
  #expect(entries["extension:broken"]?["source"] == .string("broken local copy, using bundled"))
  #expect(entries["extension:broken"]?["contract"] == .number(2))
  #expect(
    entries["extension:broken"]?["discoveryProblem"].string?.contains("uses extension contract 1") == true)
  #expect(entries["extension:broken"]?["userJSONProblem"].string?.contains("Invalid user.json") == true)
  #expect(entries["extension:stranded"]?["contract"] == .number(1))
  #expect(entries["extension:stranded"]?["activeFolder"] == .null)

  #expect(report["config"]["resultsOnlyWhenTyping"].bool)
  #expect(report["config"]["agentLogPath"] == .string(root.appending(path: "agent.log").path))
  #expect(report["permissions"]["live"]["accessibility"] == .string("denied"))
  #expect(report["permissions"]["live"]["microphone"] == .string("granted"))
  #expect(report["permissions"]["recorded"]["calendar"]["status"] == .string("askable"))
  #expect(report["permissions"]["recorded"]["calendar"]["checkedAt"].string != nil)
  #expect(report["permissions"]["note"].string?.contains("from Wicket's agent") == true)
  #expect(report["runtime"]["bindingProblem"].string?.contains("could not be registered") == true)
  #expect(report["hotkeys"]["launcher"]["resolution"] == .string("ok"))
  #expect(
    report["hotkeys"]["bindings"].array.compactMap { $0["resolution"].string }
      == [
        "ok", "disabled", "missing extension", "missing item", "missing permission", "duplicate",
        "conflicts with launcher", "registration failed",
      ])
  #expect(!String(decoding: data, as: UTF8.self).contains("private-query"))
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "extension-data").path))
}

@Test func diagnoseCLILeavesMissingFilesAloneAndReportsBadConfig() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let config = root.appending(path: "config.json")
  let (status, report) = try await cli(root, ["--diagnose"])
  #expect(status == 0)
  #expect(report["app"]["signing"] != .null)
  #expect(report["runtime"] == .null)
  #expect(report["runtimeReason"].string?.contains("never written") == true)
  #expect(!FileManager.default.fileExists(atPath: config.path))
  try Data("{".utf8).write(to: config)
  let (badStatus, badReport) = try await cli(root, ["--diagnose"])
  #expect(badStatus == 0)
  #expect(badReport["config"]["problem"].string?.hasPrefix("Config: ") == true)
  let (_, help) = try await cli(root, ["--help"])
  #expect(help["usage"].string?.contains("--diagnose") == true)
}

@MainActor @Test func runtimeRecordsOnlyExtensionFailuresAndBoundsThePrivateFile() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let sentinel = "private-request-sentinel"
  let script = "cat >/dev/null; printf '%s' '\(String(repeating: "é", count: 1500)) tail' >&2; exit 7"
  _ = try extensionFolder(
    root, name: "fail", script: script,
    fields: [
      "submit": true,
      "items": [
        ["id": "run", "title": "Fail", "actions": [["type": "run", "action": "run", "hidden": true]]]
      ],
    ])
  _ = try extensionFolder(root, name: "pattern", script: script, fields: ["match": "^pattern$"])
  _ = try extensionFolder(root, name: "silent", script: "cat >/dev/null")
  _ = try extensionFolder(root, name: "good", script: answering("Success"))

  let url = root.appending(path: "runtime.json")
  let recorder = RuntimeRecorder(url: url)
  let model = LauncherModel(
    history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: nil,
    runtime: recorder)
  model.extensions.permissions = deniedPermissions
  recorder.observePermissions(deniedPermissions)
  let initial = recorder.record.updatedAt
  recorder.observePermissions(deniedPermissions)
  await model.extensions.reload()
  model.navigator.editInput("ordinary typing")
  await model.navigator.settled()
  model.navigator.go(Address(id: "extension:good"))
  await model.navigator.settled()
  model.navigator.runHidden(Address(id: "extension:silent", hidden: true), from: nil)
  await model.navigator.settled()
  #expect(recorder.record.updatedAt == initial)
  #expect(recorder.record.recentFailures.isEmpty)

  model.navigator.go(
    Address(id: "extension:fail", input: sentinel, fields: ["secret": sentinel], action: "run"),
    submitted: true)
  await model.navigator.settled()
  model.press(HotkeyTarget(target: "extension:fail", input: sentinel, item: "run"))
  await model.navigator.settled()
  model.navigator.runHidden(Address(id: "extension:fail", action: "run", hidden: true), from: nil)
  await model.navigator.settled()
  model.navigator.go(Address(extensionName: "", input: "Fail"))
  await model.navigator.settled()
  let item = try #require(model.navigator.results.first { $0.rootExtensionRow == .item })
  model.navigator.runRow(item)
  await model.navigator.settled()
  model.navigator.go(Address(extensionName: "", input: "pattern"))
  await model.navigator.settled()
  let first = recorder.record.recentFailures
  #expect(first.map(\.trigger) == [.command, .hotkey, .hiddenRun, .item, .rootPattern])
  #expect(first.first?.action == "run")
  #expect(first.allSatisfy { $0.exitCode == 7 && $0.message == "Extension exited with status 7" })
  let tail = try #require(first.first?.stderrTail)
  #expect(tail.utf8.count <= 2048 && tail.hasSuffix(" tail") && !tail.contains("�"))

  for number in 0..<12 {
    recorder.extensionFailed(
      "extension:\(number)", trigger: .command, action: nil, error: ExtensionFailure("bad"))
  }
  await model.finish()
  let saved = try RuntimeRecord.read(url)
  #expect(saved.recentFailures.map(\.extensionID) == (2..<12).map { "extension:\($0)" })
  #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
}

@MainActor @Test func runtimePersistsVoiceFailureAndExcludesRequestPayload() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "runtime.json")
  let recorder = RuntimeRecorder(url: url)
  let source = FakeTranscriber()
  let voice = VoiceInput(transcriber: { source }, runtime: recorder, write: { _ in })
  voice.toggle()
  source.feeds[0].finish(
    throwing: VoiceSystemError(category: .inputChanged, domain: "Fixture.Audio", code: -17))
  #expect(await eventually { recorder.record.lastVoiceFailure != nil })
  let failure = try #require(recorder.record.lastVoiceFailure)
  #expect(failure.errorCase == "inputChanged" && failure.osDomain == "Fixture.Audio" && failure.osCode == -17)
  #expect(failure.stopReason == "failed")

  let folder = try extensionFolder(root, script: "cat >/dev/null; echo repair >&2; exit 1")
  let host = ExtensionHost(folder: root, bundled: nil, runtime: recorder)
  await host.reload()
  let command = try #require(host.commands["extension:test"])
  let sentinel = "private-request-sentinel"
  do {
    _ = try await host.view(command, request: .init(input: sentinel, fields: ["secret": sentinel]))
    Issue.record("The failing script returned a view")
  } catch {
    #expect(error.localizedDescription.contains("repair"))
  }
  #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "ran").path))
  await recorder.finish()
  #expect(!(try String(contentsOf: url, encoding: .utf8)).contains(sentinel))
}
