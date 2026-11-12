import Foundation

extension AgentConfiguration.Agent {
  /// The CLI behind the name in the interface.
  var product: String { self == .claude ? "Claude Code" : "Codex" }
  var signIn: String { rawValue + (self == .claude ? " auth login" : " login") }
  /// What a turn that failed because the CLI is signed out says.
  var signedOut: String { "Sign in first: \(signIn)" }
}

/// Finding an installed CLI, checking its login and starting it. Wicket bundles nothing and keeps
/// no credentials: if `claude` or `codex` is installed and signed in, it works.
enum AgentCLI {
  static func executable(
    _ agent: AgentConfiguration.Agent, in environment: [String: String] = Launch.environment()
  ) throws -> URL {
    guard let cli = Launch.which(agent.rawValue, in: environment) else {
      throw AgentFailure(
        "\(agent.product) isn't installed. Install it, then run \(agent.signIn) in Terminal.")
    }
    return cli
  }

  static func installed(_ agent: AgentConfiguration.Agent) -> Bool { Launch.which(agent.rawValue) != nil }

  enum SignIn: Sendable { case signedIn, signedOut, unknown }

  /// The CLI's own status command, with no model call, for Settings. A question never waits for
  /// it: a signed-out run fails with the CLI's own error, which the translator recognizes.
  static func signIn(_ agent: AgentConfiguration.Agent) async -> SignIn {
    guard let cli = try? executable(agent) else { return .unknown }
    return await signIn(
      cli, arguments: agent == .claude ? ["auth", "status", "--json"] : ["login", "status"])
  }

  /// A logged-out CLI exits nonzero, and Claude also says `"loggedIn": false`.
  static func signIn(_ cli: URL, arguments: [String]) async -> SignIn {
    let folder = FileManager.default.temporaryDirectory
    guard let (exit, output) = try? await Launch.capture(cli, arguments, in: folder, limit: .seconds(8))
    else { return .unknown }
    let auth = try? JSONDecoder().decode(JSONValue.self, from: output)
    return exit.isClean && auth?["loggedIn"] != .bool(false) ? .signedIn : .signedOut
  }

  /// What the agent is told once per conversation, as system or developer instructions: the bundled
  /// `agent-instructions.md` with its placeholders filled in, then the owner's `instructions.md`
  /// if it has any text.
  static func instructions(
    in folder: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let executable = environment["WICKET_EXECUTABLE"] ?? Bundle.main.executableURL?.path ?? "Wicket"
    var base =
      (try? String(
        contentsOf: Bundle.wicket.url(forResource: "agent-instructions", withExtension: "md")!,
        encoding: .utf8)) ?? ""
    for (key, value) in [
      "{{executable}}": executable, "{{folder}}": folder.path,
      "{{config}}": folder.appending(path: "config.json").path,
      "{{contract}}": folder.appending(path: "extension-contract.md").path,
      "{{extensions}}": folder.appending(path: "extensions").path,
    ] {
      base = base.replacingOccurrences(of: key, with: value)
    }
    let own =
      (try? String(contentsOf: folder.appending(path: "instructions.md"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return own.isEmpty ? base : base + "\n## The owner's additions\n\n" + own + "\n"
  }

  /// Starts the CLI in `folder`, continuing `resume` if given. A new conversation gets Wicket's
  /// instructions; a resumed one already has them.
  @MainActor
  static func connect(
    _ settings: AgentConfiguration, folder: URL, resume: String?, log: AgentLog,
    environment: [String: String] = Launch.environment()
  ) throws -> any AgentConnection {
    let agent = settings.agent
    let cli = try executable(agent, in: environment)
    let instructions = instructions(in: folder)
    switch agent {
    case .claude:
      return try link(ClaudeTranslator(), cli, settings, folder, resume, instructions, log)
    case .codex:
      return try link(
        CodexTranslator(folder: folder, resume: resume, settings: settings, instructions: instructions), cli,
        settings, folder, resume, instructions, log)
    }
  }
  @MainActor
  private static func link<T: Translator>(
    _ translator: T, _ cli: URL, _ settings: AgentConfiguration, _ folder: URL, _ resume: String?,
    _ instructions: String, _ log: AgentLog
  ) throws -> AgentLink<T> {
    let command = [cli.path] + T.arguments(for: settings, resume: resume, instructions: instructions)
    let run = log.begin(settings, command: command, folder: folder)
    do {
      return AgentLink(translator, lines: try JSONLines(command: command, folder: folder, log: run), log: run)
    } catch {
      run.note("END", "failed to start: \(error.localizedDescription)")
      run.close()
      throw error
    }
  }
}
