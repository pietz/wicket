import Foundation

extension AgentConfiguration.Agent {
  /// The CLI behind the name in the interface.
  var product: String { self == .claude ? "Claude Code" : "Codex" }
  var signIn: String { rawValue + (self == .claude ? " auth login" : " login") }
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

  /// The CLI's own status command, with no model call. A logged-out CLI exits nonzero, and Claude
  /// also says `"loggedIn": false`.
  static func checkLogin(
    _ cli: URL, arguments: [String], signIn: String, in folder: URL
  ) async throws {
    guard let (exit, output) = try await Launch.capture(cli, arguments, in: folder, limit: .seconds(8)) else {
      throw AgentFailure("Login check timed out. Run \(cli.lastPathComponent) in Terminal to repair it.")
    }
    let auth = try? JSONDecoder().decode(JSONValue.self, from: output)
    guard exit.isClean, auth?["loggedIn"] != .bool(false) else {
      throw AgentFailure("Sign in first: \(signIn)")
    }
  }

  /// Checks the login, then starts the CLI in `folder`, continuing `resume` if given.
  @MainActor
  static func connect(_ settings: AgentConfiguration, folder: URL, resume: String?) async throws
    -> any AgentConnection
  {
    let agent = settings.agent
    let cli = try executable(agent)
    try await checkLogin(
      cli, arguments: agent == .claude ? ["auth", "status", "--json"] : ["login", "status"],
      signIn: agent.signIn, in: folder)
    switch agent {
    case .claude: return try link(ClaudeTranslator(), cli, settings, folder, resume)
    case .codex:
      return try link(
        CodexTranslator(folder: folder, resume: resume, settings: settings), cli, settings, folder, resume)
    }
  }
  @MainActor
  private static func link<T: Translator>(
    _ translator: T, _ cli: URL, _ settings: AgentConfiguration, _ folder: URL, _ resume: String?
  ) throws -> AgentLink<T> {
    AgentLink(
      translator,
      lines: try JSONLines(command: [cli.path] + T.arguments(for: settings, resume: resume), folder: folder))
  }
}
