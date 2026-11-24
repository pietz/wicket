import Darwin
import Foundation
import Security

/// Read-only inventory. Only the app can report whether macOS accepted a global shortcut.
@MainActor
enum Diagnostics {
  static let agentEnvironmentKey = "WICKET_DIAGNOSE_FROM_AGENT"

  private struct App: Encodable {
    let edition: String
    let version: String?
    let build: String?
    let bundleID: String?
    let bundlePath: String
    let signing: Signing
    let note =
      "macOS grants permissions per signed copy. A different path or signature from the copy in System Settings can explain a switch that looks on."
  }

  private struct Signing: Encodable {
    var teamID: String?
    var adHoc: Bool?
    var satisfiesDesignatedRequirement: Bool?
    var cdhash: String?
    var status: OSStatus?
    init(_ target: URL) {
      var code: SecStaticCode?
      let create = SecStaticCodeCreateWithPath(target as CFURL, [], &code)
      guard create == errSecSuccess, let code else {
        status = create
        return
      }
      var info: CFDictionary?
      let copy = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
      if let signing = info as? [String: Any], copy == errSecSuccess {
        teamID = signing[kSecCodeInfoTeamIdentifier as String] as? String
        if let flags = signing[kSecCodeInfoFlags as String] as? UInt32 {
          adHoc = SecCodeSignatureFlags(rawValue: flags).contains(.adhoc)
        }
        cdhash = (signing[kSecCodeInfoUnique as String] as? Data)?.map {
          String(format: "%02x", $0)
        }.joined()
      } else {
        status = copy
      }
      var requirement: SecRequirement?
      if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement {
        satisfiesDesignatedRequirement =
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement)
          == errSecSuccess
      } else {
        satisfiesDesignatedRequirement = false
      }
    }
  }

  private struct PermissionReport: Encodable {
    let live: [String: Permission.Status]
    let recorded: [String: RuntimeRecord.PermissionCheck]?
    let note: String
  }
  private struct Config: Encodable {
    let problem: String?
    let workingFolder: String
    let resultsOnlyWhenTyping: Bool
    let agent: AgentConfiguration.Agent
    let agentCLIInstalled: Bool
    let agentLogPath: String
  }
  private struct Extension: Encodable {
    let id: String
    let name: String
    let enabled: Bool
    let source: String
    let activeFolder: String?
    let localFolder: String?
    let contract: Int?
    let permissions: [Permission]
    let missingPermissions: [Permission]
    let discoveryProblem: String?
    let userJSONProblem: String?
  }
  private struct Hotkeys: Encodable {
    let launcher: HotkeyRegistrations.Entry
    let bindings: [HotkeyRegistrations.Entry]
    let note: String
  }
  private struct Report: Encodable {
    let app: App
    let permissions: PermissionReport
    let config: Config
    let extensions: [Extension]
    let hotkeys: Hotkeys
    let runtime: RuntimeRecord?
    let runtimeReason: String?

    enum CodingKeys: String, CodingKey {
      case app, permissions, config, extensions, hotkeys, runtime, runtimeReason
    }
    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(app, forKey: .app)
      try values.encode(permissions, forKey: .permissions)
      try values.encode(config, forKey: .config)
      try values.encode(extensions, forKey: .extensions)
      try values.encode(hotkeys, forKey: .hotkeys)
      try values.encode(runtime, forKey: .runtime)
      try values.encodeIfPresent(runtimeReason, forKey: .runtimeReason)
    }
  }

  static func report(
    folder: URL, bundled: URL? = ExtensionHost.bundledFolder, permissions: Permissions = .system,
    edition: Edition = .current, environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> Data {
    let store = ConfigurationStore(url: folder.appending(path: "config.json"))
    store.load()
    let host = ExtensionHost(folder: folder, bundled: bundled)
    let directory = CommandDirectory(extensions: host, hosts: [], store: store)
    await host.reload()
    let configuration = store.configuration
    let log = AgentLog.standard(edition: edition, environment: environment)
    let (runtime, reason) = readRuntime(beside: log)
    let live = permissions.snapshot()
    let appPermissions = runtime?.permissions.mapValues(\.status) ?? live
    func permissionStatus(_ permission: Permission) -> Permission.Status {
      appPermissions[permission.rawValue] ?? .denied
    }
    let attribution =
      environment[agentEnvironmentKey] == "1"
      ? "This command was run from Wicket's agent, so macOS normally attributes permission checks to Wicket."
      : "This command was run outside Wicket's agent. macOS normally attributes checks to the launching app, such as Terminal."
    let permissionSource =
      runtime == nil
      ? "Extension and hotkey checks use live permissions."
      : "Extension and hotkey checks use the app's recorded permissions."
    let bundle = Bundle.main
    let signingTarget =
      bundle.bundleURL.pathExtension == "app"
      ? bundle.bundleURL : bundle.executableURL ?? bundle.bundleURL
    let report = Report(
      app: App(
        edition: edition.name, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
        build: bundle.infoDictionary?["CFBundleVersion"] as? String, bundleID: bundle.bundleIdentifier,
        bundlePath: bundle.bundleURL.path, signing: Signing(signingTarget)),
      permissions: PermissionReport(
        live: live, recorded: runtime?.permissions, note: attribution + " " + permissionSource),
      config: Config(
        problem: store.problem, workingFolder: folder.path,
        resultsOnlyWhenTyping: configuration.resultsOnlyWhenTyping, agent: configuration.agent.agent,
        agentCLIInstalled: (try? AgentCLI.executable(
          configuration.agent.agent, in: Launch.environment(environment)))
          != nil, agentLogPath: log.file.path),
      extensions: host.ids.sorted().map { id in
        extensionReport(id, host: host, configuration: configuration, permissionStatus: permissionStatus)
      },
      hotkeys: hotkeyReport(directory, recorded: runtime?.registrations, permissionStatus: permissionStatus),
      runtime: runtime, runtimeReason: reason)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(report)
  }

  private static func readRuntime(beside log: AgentLog) -> (RuntimeRecord?, String?) {
    let url = RuntimeRecord.url(beside: log)
    do {
      let record = try RuntimeRecord.read(url)
      guard record.pid > 0, kill(record.pid, 0) == 0 || errno == EPERM else {
        return (nil, "The app process that wrote runtime.json is no longer running.")
      }
      return (record, nil)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return (nil, "The app has never written runtime.json here.")
    } catch {
      return (nil, "runtime.json could not be read.")
    }
  }

  private static func extensionReport(
    _ id: String, host: ExtensionHost, configuration: Configuration,
    permissionStatus: (Permission) -> Permission.Status
  ) -> Extension {
    let name = String(id.dropFirst("extension:".count))
    let command = host.commands[id]
    let problem = host.problems[id]
    let local = host.localCopies[id]
    let localFolder = host.folder.appending(path: "extensions").appending(path: name)
    let source: String
    if local?.retired == true {
      source = "retired local copy ignored"
    } else if problem?.usingBundled == true {
      source = "broken local copy, using bundled"
    } else if local != nil {
      source = command != nil && host.hasBundled(name) ? "local overriding bundled" : "local"
    } else {
      source = "bundled"
    }
    return Extension(
      id: id, name: command?.manifest.name ?? problem?.name ?? name,
      enabled: configuration.isEnabled(id, extensions: host.ids), source: source,
      activeFolder: command?.folder.path,
      localFolder: local?.folder.path
        ?? (FileManager.default.fileExists(atPath: localFolder.appending(path: "user.json").path)
          ? localFolder.path : nil),
      contract: command?.manifest.contract ?? problem?.contract,
      permissions: command?.manifest.permissions ?? [],
      missingPermissions: command.map { Permissions.missing($0, status: permissionStatus) } ?? [],
      discoveryProblem: problem?.manifest,
      userJSONProblem: problem?.userItems)
  }

  private static func hotkeyReport(
    _ directory: CommandDirectory, recorded: HotkeyRegistrations?,
    permissionStatus: (Permission) -> Permission.Status
  ) -> Hotkeys {
    let config = directory.store.configuration
    let launcher = HotKeyRegistration { _ in NSObject() }
    let bindings = CommandHotKeys { _, _ in NSObject() }
    let problem = launcher.apply(config.hotkey)
    _ = bindings.apply(config.hotkeys, launcher: launcher.inEffect)
    let actual = recorded.flatMap { recorded in
      recorded.launcher.shortcut == config.hotkey.description
        && recorded.bindings.count == bindings.latest.count
        && zip(recorded.bindings, bindings.latest).allSatisfy {
          $0.shortcut == $1.shortcut && $0.target == $1.target
        } ? recorded : nil
    }
    var main = actual?.launcher ?? launcher.snapshot(config.hotkey, problem: problem)
    if actual == nil { main.inEffect = nil }
    let entries = zip(config.hotkeys, actual?.bindings ?? bindings.latest).map { binding, entry in
      var entry = entry
      if actual == nil { entry.inEffect = nil }
      if entry.resolution == .ok {
        entry.resolution = directory.hotkeyResolution(binding.target, permissionStatus: permissionStatus)
      }
      return entry
    }
    return Hotkeys(
      launcher: main, bindings: entries,
      note: actual == nil
        ? "Checks configuration and targets. No matching global registration record is available."
        : "Global registration comes from the running app.")
  }
}
