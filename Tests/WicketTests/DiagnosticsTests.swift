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
  for name in ["built-in", "override", "broken", "units", "mixed", "personal"] {
    _ = try extensionFolder(bundledBase, name: name, script: script)
  }
  let local = try extensionFolder(root, name: "local", script: script, fields: ["permissions": ["calendar"]])
  let override = try extensionFolder(root, name: "override", script: script)
  let broken = try extensionFolder(root, name: "broken", script: script, fields: ["contract": 1])
  _ = try extensionFolder(root, name: "stranded", script: script, fields: ["contract": 1])
  let mixed = try extensionFolder(root, name: "Mixed", script: script)
  let personal = root.appending(path: "extensions/personal")
  try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
  try Data(#"{"items":[]}"#.utf8).write(to: personal.appending(path: "user.json"))
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
  recorder.observePermissions(deniedPermissions.snapshot())
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
  #expect(entries["extension:Mixed"]?["source"] == .string("local"))
  #expect(try pointsTo("extension:Mixed", "activeFolder", mixed))
  #expect(entries["extension:mixed"]?["source"] == .string("bundled"))
  #expect(entries["extension:personal"]?["source"] == .string("bundled"))
  #expect(try pointsTo("extension:personal", "localFolder", personal))
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
  #expect(report["runtimeIsLive"] == .bool(true))
  #expect(report["runtime"]["bundlePath"] == .string(Bundle.main.bundleURL.path))
  #expect(report["runtime"]["executablePath"].string != nil)
  #expect(report["runtime"]["processStartTimeMicroseconds"] != .null)
  #expect(report["runtime"]["bindingProblem"].string?.contains("could not be registered") == true)
  #expect(report["hotkeys"]["launcher"]["resolution"] == .string("ok"))
  #expect(
    report["hotkeys"]["bindings"].array.compactMap { $0["resolution"].string }
      == [
        "ok", "disabled", "missing extension", "missing item", "missing permission", "duplicate",
        "conflicts with launcher", "ok",
      ])
  #expect(report["hotkeys"]["launcher"]["registration"] == .string("registered"))
  #expect(
    report["hotkeys"]["bindings"].array.compactMap { $0["registration"].string }
      == ["registered", "registered", "registered", "registered", "registered", "failed", "failed", "failed"])
  #expect(!String(decoding: data, as: UTF8.self).contains("private-query"))
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "extension-data").path))

  config.hotkeys[0].keys = try Shortcut("ctrl+8")
  try config.save(at: root.appending(path: "config.json"))
  let changed = try JSONDecoder().decode(
    JSONValue.self,
    from: await Diagnostics.report(
      folder: root, bundled: bundled, permissions: deniedPermissions, environment: env))
  let changedBindings = changed["hotkeys"]["bindings"].array
  #expect(changedBindings[0]["resolution"] == .string("ok"))
  #expect(changedBindings[0]["registration"] == .string("unknown"))
  #expect(changedBindings[0]["inEffect"] == .null)
  #expect(changedBindings[1]["registration"] == .string("registered"))

  try Data("{".utf8).write(to: root.appending(path: "config.json"))
  let malformed = try JSONDecoder().decode(
    JSONValue.self,
    from: await Diagnostics.report(
      folder: root, bundled: bundled, permissions: deniedPermissions, environment: env))
  let unknown = JSONValue.string("unknown (config.json could not be read)")
  #expect(malformed["config"]["problem"].string?.hasPrefix("Config: ") == true)
  for field in ["resultsOnlyWhenTyping", "agent", "agentCLIInstalled"] {
    #expect(malformed["config"][field] == .null)
  }
  #expect(malformed["extensions"].array.count == entries.count)
  #expect(malformed["extensions"].array.allSatisfy { $0["enabled"] == unknown })
  #expect(malformed["hotkeys"]["launcher"]["resolution"] == unknown)
  #expect(malformed["hotkeys"]["launcher"]["inEffect"] == .string(config.hotkey.description))
  let recordedBindings = malformed["hotkeys"]["bindings"].array
  #expect(recordedBindings.count == config.hotkeys.count)
  #expect(recordedBindings.allSatisfy { $0["resolution"] == unknown })
  #expect(recordedBindings.first?["shortcut"] == .string("ctrl+1"))
  #expect(recordedBindings.first?["registration"] == .string("registered"))
}

@Test func diagnoseCLILeavesMissingFilesAloneAndReportsBadConfig() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let config = root.appending(path: "config.json")
  let (status, report) = try await cli(root, ["--diagnose"])
  #expect(status == 0)
  #expect(report["app"]["signing"]["satisfiesDesignatedRequirement"] == .bool(true))
  #expect(report["app"]["signing"]["designatedRequirement"].string?.isEmpty == false)
  #expect(report["runtime"] == .null)
  #expect(report["runtimeReason"].string?.contains("never written") == true)
  #expect(!FileManager.default.fileExists(atPath: config.path))
  try Data("{".utf8).write(to: config)
  let (badStatus, badReport) = try await cli(root, ["--diagnose"])
  #expect(badStatus == 0)
  #expect(badReport["config"]["problem"].string?.hasPrefix("Config: ") == true)
  #expect(badReport["hotkeys"]["launcher"]["registration"] == .string("unknown"))
  #expect(badReport["hotkeys"]["launcher"]["shortcut"] == .null)
  let (_, help) = try await cli(root, ["--help"])
  #expect(help["usage"].string?.contains("--diagnose") == true)
}

private enum OldRuntimeWriter: CaseIterable { case exited, moved, reusedPID, legacy }

@MainActor @Test(arguments: OldRuntimeWriter.allCases)
private func diagnosticsKeepsStaleRuntimeHistory(_ writer: OldRuntimeWriter) async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let config = Configuration()
  try config.save(at: root.appending(path: "config.json"))
  let env = ["WICKET_CONFIG_DIR": root.path]
  let url = RuntimeRecord.url(beside: AgentLog.standard(environment: env))
  let bundle = "/Old Location/Wicket.app"
  let path = bundle + "/Contents/MacOS/Wicket"
  let start: UInt64 = 1_800_000_000_122_051
  let record = RuntimeRecord(
    pid: 1234, executablePath: writer == .legacy ? nil : path,
    bundlePath: writer == .legacy ? nil : bundle,
    processStartTimeMicroseconds: writer == .legacy ? nil : start,
    updatedAt: Date(), permissions: ["accessibility": .init(status: .granted, checkedAt: Date())],
    registrations: .init(
      launcher: .init(shortcut: config.hotkey.description, inEffect: config.hotkey.description),
      bindings: []),
    recentFailures: [
      .init(
        at: Date(), extensionID: "extension:fixture", trigger: .command, action: nil,
        message: "Fixture failure", exitCode: 1, stderrTail: nil)
    ])
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode(record).write(to: url)

  let data = try await Diagnostics.report(
    folder: root, bundled: nil, permissions: deniedPermissions, environment: env,
    process: { pid in
      #expect(pid == record.pid)
      switch writer {
      case .exited: return nil
      case .moved:
        return .init(
          executablePath: "/Applications/Wicket.app/Contents/MacOS/Wicket", startTimeMicroseconds: start)
      case .reusedPID: return .init(executablePath: path, startTimeMicroseconds: start + 1)
      case .legacy: return .init(executablePath: path, startTimeMicroseconds: start)
      }
    })
  let report = try JSONDecoder().decode(JSONValue.self, from: data)
  #expect(report["runtimeIsLive"] == .bool(false))
  #expect(report["runtimeReason"].string?.contains("no longer running") == true)
  #expect(report["runtime"]["bundlePath"].string == record.bundlePath)
  #expect(report["runtime"]["executablePath"].string == record.executablePath)
  #expect(report["runtime"]["recentFailures"].array.first?["message"] == .string("Fixture failure"))
  #expect(report["permissions"]["recorded"]["accessibility"]["status"] == .string("granted"))
  #expect(report["permissions"]["note"].string?.contains("checks use live permissions") == true)
  #expect(report["hotkeys"]["launcher"]["registration"] == .string("unknown"))
  #expect(report["hotkeys"]["launcher"]["inEffect"] == .null)
}

@MainActor @Test func reopeningCollectsPermissionSnapshotsOffMain() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let recorder = RuntimeRecorder()
  let model = LauncherModel(
    history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: nil,
    runtime: recorder)
  model.extensions.permissions = Permissions(
    status: { permission in
      #expect(!Thread.isMainThread)
      return permission == .calendar ? .askable : .denied
    },
    request: { _ in Issue.record("Diagnostics asked for a permission") },
    microphone: {
      #expect(!Thread.isMainThread)
      return .granted
    })
  model.reopen()
  #expect(recorder.record.permissions.isEmpty)
  await model.finish()
  #expect(
    recorder.record.permissions.mapValues(\.status) == [
      "accessibility": .denied, "calendar": .askable, "microphone": .granted,
    ])
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
  recorder.observePermissions(deniedPermissions.snapshot())
  let initial = recorder.record.updatedAt
  recorder.observePermissions(deniedPermissions.snapshot())
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

  let folder = try extensionFolder(
    root, script: "cat >/dev/null; echo repair >&2; exit 1",
    fields: ["settings": [["name": "token", "type": "text", "description": "Token"]]])
  let host = ExtensionHost(folder: root, bundled: nil, runtime: recorder)
  let sentinel = "private-request-sentinel"
  host.settings["test"] = ["token": sentinel]
  await host.reload()
  let command = try #require(host.commands["extension:test"])
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
