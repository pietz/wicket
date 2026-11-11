import Foundation
import Testing

@testable import WicketApp

extension ConfigurationStore {
  /// Tests set configuration the way anything else does: by writing the file.
  func update(_ edit: (inout Configuration) -> Void) {
    var value = configuration
    edit(&value)
    try? value.save(at: url)
    load()
  }
}

/// Finishes one question through the real session and a fake agent, whose process ends with the turn.
@MainActor @discardableResult
func finishTurn(_ session: AgentSession, _ question: String, _ answer: String) async throws -> FakeAgent {
  let fake = FakeAgent()
  session.connect = { _, _, _ in fake }
  session.ask(question, settings: .init())
  #expect(await eventually { fake.running })
  fake.text(answer)
  fake.end()
  #expect(await eventually { !session.busy && fake.stopped })
  return fake
}
