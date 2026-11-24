import Darwin
import Foundation
import Security

/// Read-only inventory. Only the app can report whether macOS accepted a global shortcut.
@MainActor
enum Diagnostics {
  private static let unreadableConfig = "unknown (config.json could not be read)"

  private struct App: Encodable {
    let edition: String
    let version: String?
    let build: String?
    let bundleID: String?
    let bundlePath: String
    let executablePath: String?
    let signing: Signing
    let note =
      "macOS grants permissions per signed copy. A different path or signature from the copy in System Settings can explain a switch that looks on."
  }

  private struct Signing: Encodable {
    var teamID: String?
    var adHoc: Bool?
    var designatedRequirement: String?
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
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
          designatedRequirement = text as String?
        }
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
    let discrepancy: String?
    let note: String
  }
  private struct Config: Encodable {
    let problem: String?
    let workingFolder: String
    let resultsOnlyWhenTyping: Bool?
    let agent: AgentConfiguration.Agent?
    let agentCLIInstalled: Bool?
    let agentLogPath: String
  }
  private struct Extension: Encodable {
    let id: String
    let name: String
    let enabled: JSONValue
    let source: ExtensionHost.Source
    let activeFolder: String?
    let localFolder: String?
    let contract: Int?
    let permissions: [Permission]
    let missingPermissions: [Permission]
    let discoveryProblem: String?
    let settingsProblem: String?
  }
  private struct Hotkeys: Encodable {
    struct Entry: Encodable {
      enum Registration: String, Encodable { case registered, failed, unknown }

      let shortcut: String?
      let target: String?
      let resolution: String
      let registration: Registration
      let inEffect: String?
      let problem: String?

      init(
        shortcut: String? = nil, target: String? = nil, resolution: String,
        recorded: HotkeyRegistrations.Entry?
      ) {
        self.shortcut = shortcut ?? recorded?.shortcut
        self.target = target ?? recorded?.target
        self.resolution = resolution
        if let recorded, recorded.resolution != .ok {
          registration = .failed
        } else if let recorded, recorded.inEffect == recorded.shortcut {
          registration = .registered
        } else {
          registration = .unknown
        }
        inEffect = recorded?.inEffect
        problem = recorded?.problem
      }
    }
    let launcher: Entry
    let bindings: [Entry]
    let note: String
  }
  private struct Report: Encodable {
    let app: App
    let permissions: PermissionReport
    let config: Config
    let extensions: [Extension]
    let hotkeys: Hotkeys
    let runtime: RuntimeRecord?
    let runtimeIsLive: Bool?
    let runtimeReason: String?

    enum CodingKeys: String, CodingKey {
      case app, permissions, config, extensions, hotkeys, runtime, runtimeIsLive, runtimeReason
    }
    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(app, forKey: .app)
      try values.encode(permissions, forKey: .permissions)
      try values.encode(config, forKey: .config)
      try values.encode(extensions, forKey: .extensions)
      try values.encode(hotkeys, forKey: .hotkeys)
      try values.encode(runtime, forKey: .runtime)
      try values.encodeIfPresent(runtimeIsLive, forKey: .runtimeIsLive)
      try values.encodeIfPresent(runtimeReason, forKey: .runtimeReason)
    }
  }

  static func report(
    folder: URL, bundled: URL? = ExtensionHost.bundledFolder, permissions: Permissions = .system,
    edition: Edition = .current, environment: [String: String] = ProcessInfo.processInfo.environment,
    process: (Int32) -> RuntimeRecord.ProcessIdentity? = RuntimeRecord.ProcessIdentity.read,
    parent: (Int32) -> Int32? = ProcessTree.parent
  ) async throws -> Data {
    let store = ConfigurationStore(url: folder.appending(path: "config.json"))
    store.load()
    let host = ExtensionHost(folder: folder, bundled: bundled)
    _ = host.applySettings(store.configuration.extensions)
    let directory = CommandDirectory(extensions: host, hosts: [], store: store)
    await host.reload()
    let configuration = store.problem == nil ? store.configuration : nil
    let log = AgentLog.standard(edition: edition, environment: environment)
    let (runtime, reason) = readRuntime(beside: log)
    let bundle = Bundle.main
    let matchesCopy = runtime.map { matches($0, bundle: bundle) } == true
    let runtimeIsLive = runtime.map { $0.isLive(process: process) }
    let running = matchesCopy && runtimeIsLive == true ? runtime : nil
    let recorded = matchesCopy ? runtime?.permissions : nil
    let liveMatchesCopy = running.map { hasAncestor($0.pid, parent: parent) } == true
    let live = await Task.detached { permissions.snapshot() }.value
    func permissionStatus(_ permission: Permission) -> Permission.Status {
      let key = permission.rawValue
      if !liveMatchesCopy, let status = running?.permissions[key]?.status { return status }
      return live[key] ?? .denied
    }
    let permissionSource: String
    if liveMatchesCopy {
      permissionSource =
        "This command was launched by this running copy of Wicket. Extension and hotkey checks use live permissions."
    } else if running?.permissions.isEmpty == false {
      permissionSource =
        "Live permissions may reflect the launching app. Extension and hotkey checks use this copy's recorded permissions where available."
    } else if recorded?.isEmpty == false {
      permissionSource =
        "Recorded permissions are from an earlier run of this copy. Extension and hotkey checks use live permissions, which may reflect the launching app."
    } else {
      permissionSource =
        "Recorded permissions for this copy are unavailable. Extension and hotkey checks use live permissions, which may reflect the launching app."
    }
    let discrepancies = live.keys.sorted().compactMap { key -> String? in
      guard let check = recorded?[key], let status = live[key], check.status != status else { return nil }
      return
        "\(key) was recorded as \(check.status.rawValue) at \(check.checkedAt.ISO8601Format()). The live check returned \(status.rawValue)."
    }
    let runtimeReason: String?
    if !matchesCopy, let writerPath = runtime?.bundlePath ?? runtime?.executablePath {
      let state = runtimeIsLive == true ? "is running" : "could not be verified as running"
      runtimeReason =
        "runtime.json was written by another copy of Wicket at \(writerPath). Its writer \(state)."
    } else if runtimeIsLive == false {
      runtimeReason = "The writer of runtime.json could not be verified as running."
    } else {
      runtimeReason = reason
    }
    let signingTarget =
      bundle.bundleURL.pathExtension == "app"
      ? bundle.bundleURL : bundle.executableURL ?? bundle.bundleURL
    let report = Report(
      app: App(
        edition: edition.name, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
        build: bundle.infoDictionary?["CFBundleVersion"] as? String, bundleID: bundle.bundleIdentifier,
        bundlePath: bundle.bundleURL.path, executablePath: bundle.executableURL?.path,
        signing: Signing(signingTarget)),
      permissions: PermissionReport(
        live: live, recorded: recorded,
        discrepancy: discrepancies.isEmpty ? nil : discrepancies.joined(separator: " "),
        note: permissionSource),
      config: Config(
        problem: store.problem, workingFolder: folder.path,
        resultsOnlyWhenTyping: configuration?.resultsOnlyWhenTyping, agent: configuration?.agent.agent,
        agentCLIInstalled: configuration.map {
          (try? AgentCLI.executable($0.agent.agent, in: Launch.environment(environment))) != nil
        }, agentLogPath: log.file.path),
      extensions: host.locations.sorted { $0.key < $1.key }.map { id, location in
        extensionReport(
          id, location: location, host: host, configuration: configuration, permissionStatus: permissionStatus
        )
      },
      hotkeys: hotkeyReport(
        directory, configuration: configuration, recorded: running?.registrations,
        permissionStatus: permissionStatus),
      runtime: runtime, runtimeIsLive: runtimeIsLive, runtimeReason: runtimeReason)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(report)
  }

  private static func matches(_ runtime: RuntimeRecord, bundle: Bundle) -> Bool {
    guard let bundlePath = runtime.bundlePath, let executablePath = runtime.executablePath,
      let executable = bundle.executableURL
    else { return false }
    return Edition.sameFolder(URL(fileURLWithPath: bundlePath), bundle.bundleURL)
      && URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        == executable.resolvingSymlinksInPath().path
  }

  private static func hasAncestor(_ ancestor: Int32, parent: (Int32) -> Int32?) -> Bool {
    var pid = getpid()
    for _ in 0..<64 {
      guard let next = parent(pid), next > 1, next != pid else { return false }
      if next == ancestor { return true }
      pid = next
    }
    return false
  }

  private static func readRuntime(beside log: AgentLog) -> (RuntimeRecord?, String?) {
    let url = RuntimeRecord.url(beside: log)
    do {
      return (try RuntimeRecord.read(url), nil)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return (nil, "The app has never written runtime.json here.")
    } catch {
      return (nil, "runtime.json could not be read.")
    }
  }

  private static func extensionReport(
    _ id: String, location: ExtensionHost.Location, host: ExtensionHost, configuration: Configuration?,
    permissionStatus: (Permission) -> Permission.Status
  ) -> Extension {
    let name = String(id.dropFirst("extension:".count))
    let command = host.commands[id]
    let problem = host.problems[id]
    return Extension(
      id: id, name: command?.manifest.name ?? problem?.name ?? name,
      enabled: configuration.map { .bool($0.isEnabled(id, extensions: host.ids)) }
        ?? .string(unreadableConfig),
      source: location.source, activeFolder: command?.folder.path, localFolder: location.localFolder?.path,
      contract: command?.manifest.contract ?? problem?.contract,
      permissions: command?.manifest.permissions ?? [],
      missingPermissions: command.map { Permissions.missing($0, status: permissionStatus) } ?? [],
      discoveryProblem: problem?.manifest,
      settingsProblem: problem?.settings)
  }

  private static func hotkeyReport(
    _ directory: CommandDirectory, configuration: Configuration?, recorded: HotkeyRegistrations?,
    permissionStatus: (Permission) -> Permission.Status
  ) -> Hotkeys {
    guard let configuration else {
      return Hotkeys(
        launcher: .init(resolution: unreadableConfig, recorded: recorded?.launcher),
        bindings: (recorded?.bindings ?? []).map { .init(resolution: unreadableConfig, recorded: $0) },
        note: recorded == nil
          ? "config.json could not be read. No live registration record is available."
          : "config.json could not be read. Showing the running app’s last recorded registrations.")
    }

    struct RegistrationKey: Hashable {
      let shortcut: String
      let target: String?
    }
    let addresses = configuration.hotkeys.map {
      RegistrationKey(shortcut: $0.keys.description, target: HotkeyRegistrations.target($0.target))
    }
    // The runtime record deliberately omits address input. Only unambiguous entries can be matched.
    let configured = Dictionary(grouping: addresses, by: { $0 })
    let observed = Dictionary(grouping: recorded?.bindings ?? []) {
      RegistrationKey(shortcut: $0.shortcut, target: $0.target)
    }
    var seen: Set<Shortcut> = []
    let entries = zip(configuration.hotkeys, addresses).map { binding, address in
      let resolution: HotkeyRegistrations.Resolution
      if binding.keys == configuration.hotkey {
        resolution = .conflictsWithLauncher
      } else if !seen.insert(binding.keys).inserted {
        resolution = .duplicate
      } else {
        resolution = directory.hotkeyResolution(binding.target, permissionStatus: permissionStatus)
      }
      let matches = observed[address] ?? []
      return Hotkeys.Entry(
        shortcut: address.shortcut, target: address.target, resolution: resolution.rawValue,
        recorded: configured[address]?.count == 1 && matches.count == 1 ? matches.first : nil)
    }
    let shortcut = configuration.hotkey.description
    return Hotkeys(
      launcher: .init(
        shortcut: shortcut, resolution: "ok",
        recorded: recorded?.launcher.shortcut == shortcut ? recorded?.launcher : nil),
      bindings: entries,
      note: "Target checks use config.json. Registration uses matching observations from the running app.")
  }
}
