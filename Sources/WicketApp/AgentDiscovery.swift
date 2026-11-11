import Foundation

/// The models each CLI lists, asked without a model call and saved per agent.
@MainActor
enum AgentDiscovery {
  static func url(_ agent: AgentConfiguration.Agent, in folder: URL) -> URL {
    folder.appending(path: "agent-options-\(agent.rawValue).json")
  }
  static func save(_ models: [AgentModel], agent: AgentConfiguration.Agent, in folder: URL) throws {
    try JSONEncoder().encode(AgentCatalog(models: models)).write(to: url(agent, in: folder), options: .atomic)
  }
  static func load(_ agent: AgentConfiguration.Agent, in folder: URL) -> AgentCatalog? {
    try? JSONDecoder().decode(AgentCatalog.self, from: Data(contentsOf: url(agent, in: folder)))
  }

  static func discover(_ agent: AgentConfiguration.Agent, timeout: Duration = .seconds(10)) async throws
    -> [AgentModel]
  {
    let cli = try AgentCLI.executable(agent)
    let listing = agent == .claude ? ClaudeTranslator.listing : CodexTranslator.listing
    return try await models(command: [cli.path] + listing.arguments, listing: listing, timeout: timeout)
  }

  /// Runs `command`, sends the listing request and waits for the answer. The process always stops.
  static func models(command: [String], listing: Listing, timeout: Duration) async throws -> [AgentModel] {
    let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-options-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lines = try JSONLines(command: command, folder: folder)
    let (found, sink) = AsyncThrowingStream<[AgentModel], any Error>.makeStream()
    lines.onMessage = { message in
      if let models = listing.models(message) {
        sink.yield(models)
        sink.finish()
      }
    }
    lines.onClose = { sink.finish(throwing: AgentFailure("The CLI " + $0)) }
    let deadline = Task {
      try? await Task.sleep(for: timeout)
      sink.finish(throwing: AgentFailure("Timed out listing models. Check the CLI and its login."))
    }
    for line in listing.send { lines.send(line) }
    do {
      defer { deadline.cancel() }
      for try await models in found {
        await lines.stop()
        guard !models.isEmpty else { throw AgentFailure("The CLI listed no models.") }
        return models
      }
      throw AgentFailure("The CLI ended without listing models.")
    } catch {
      await lines.stop()
      throw error
    }
  }
}
