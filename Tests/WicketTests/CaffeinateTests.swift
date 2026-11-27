import Foundation
import Testing

@testable import WicketApp
@testable import caffeinate

// The bundled Caffeinate keeps the Mac awake through /usr/bin/caffeinate. Nothing here keeps this Mac
// awake: the runs that start a keeper start /bin/sleep in its place, and the bundled program runs only
// unsubmitted.

private func request(
  hours: String? = nil, minutes: String? = nil, submitted: Bool = false, action: String? = nil
) -> JSON {
  var fields: [String: JSON] = [:]
  if let hours { fields["hours"] = .string(hours) }
  if let minutes { fields["minutes"] = .string(minutes) }
  var request: [String: JSON] = [
    "input": .string(hours ?? ""), "fields": .object(fields), "submitted": .bool(submitted),
  ]
  if let action { request["action"] = .string(action) }
  return .object(request)
}

private func rows(_ answer: String) throws -> [Row] {
  try JSONDecoder().decode(ProviderView.self, from: Data(answer.utf8)).items
}

/// Reaps a stand-in keeper this test process started, once it was told to stop.
private func ended(_ pid: pid_t) -> Bool {
  var status: Int32 = 0
  return waitpid(pid, &status, 0) == pid
}

@Test func theKeeperHoldsTheDisplayAndSystemAwakeForTheDuration() {
  #expect(keepAwake(5400) == ["/usr/bin/caffeinate", "-d", "-i", "-t", "5400"])
  #expect(keepAwake(nil) == ["/usr/bin/caffeinate", "-d", "-i"])
}

@Test(arguments: [
  ("2", "", Draft.seconds(7200)), ("1,5", "30", .seconds(7200)), (" 0.5 ", "", .seconds(1800)),
  ("", "", .empty), ("0", "", .seconds(0)), ("-1", "", .invalid), ("two", "", .invalid),
  ("", "abc", .invalid), ("1e9", "", .invalid),
])
func durationsComeFromHoursMinutesAndSeconds(hours: String, minutes: String, expected: Draft) {
  #expect(draft(hours: hours, minutes: minutes, seconds: "") == expected)
}

@Test func onlyASubmittedChoiceStartsReplacesOrStopsTheKeeper() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let now = time(nil)
  var asked: [Int?] = []
  func answered(_ request: JSON) -> String {
    answer(request, folder: folder.path, now: now) {
      asked.append($0)
      return ["/bin/sleep", "600"]
    }
  }

  // Entering, typing and links only describe; a typed duration leads with what Return starts.
  var shown = try rows(answered(request()))
  #expect(shown.map(\.title) == ["Keep Awake"] && shown[0].subtitle == "Until you turn it off")
  #expect(shown[0].actions.map(\.kind) == [.run(Address(action: "start"))])
  shown = try rows(answered(request(hours: "2", minutes: "30")))
  #expect(shown.map(\.title) == ["Keep Awake for 2 h 30 min"])
  #expect(shown[0].subtitle == "Until " + clock(now + 9000, now: now))
  _ = answered(request(submitted: true))
  _ = answered(request(hours: "x", submitted: true, action: "start"))
  #expect(asked.isEmpty && running(in: folder.path) == nil)

  // `caff 2` at the root: submitted with hours and no action. The keeper leaves this session.
  shown = try rows(answered(request(hours: "2", submitted: true)))
  let first = try #require(running(in: folder.path))
  #expect(asked == [7200] && first.until == now + 7200)
  #expect(getsid(first.pid) == first.pid && getpgid(first.pid) == first.pid)
  #expect(shown.map(\.title) == ["Awake until " + clock(now + 7200, now: now)])
  #expect(shown[0].subtitle == "2 h left")
  #expect(shown[0].actions.map(\.kind) == [.run(Address(action: "stop"))])

  // A typed duration leads while one runs; nothing typed shows the state first.
  #expect(try rows(answered(request(minutes: "5"))).map(\.id) == ["start", "awake"])
  #expect(try rows(answered(request())).map(\.id) == ["awake", "start"])

  // Keep Awake with nothing typed replaces it with one that runs until turned off.
  shown = try rows(answered(request(submitted: true, action: "start")))
  let second = try #require(running(in: folder.path))
  #expect(asked == [7200, nil] && second.until == nil && second.pid != first.pid)
  #expect(ended(first.pid))
  #expect(shown.map(\.title) == ["Awake until you turn it off"])

  // Turn Off stops it and forgets it.
  shown = try rows(answered(request(submitted: true, action: "stop")))
  #expect(ended(second.pid) && running(in: folder.path) == nil)
  #expect(shown.map(\.title) == ["Keep Awake"] && asked.count == 2)
}

@Test func aProcessThatReusedTheRecordedPidIsLeftAlone() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let other = try #require(detach(["/bin/sleep", "600"]))
  defer {
    kill(other, SIGKILL)
    _ = ended(other)
  }
  let start = try #require(startTime(of: other))
  try "\(other) \(start - 1) 0\n".write(
    to: folder.appending(path: "awake"), atomically: true, encoding: .utf8)
  #expect(running(in: folder.path) == nil)
  let shown = try rows(answer(request(submitted: true, action: "stop"), folder: folder.path))
  #expect(shown.map(\.title) == ["Keep Awake"] && startTime(of: other) == start)
}

/// `caff 2` fills the hours, so Return submits them; minutes and seconds stay slots.
@MainActor @Test func theKeywordsArgumentIsTheHours() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel.testing(in: root, bundled: bundledExtensions)
  await model.extensions.reload()
  model.navigator.input = "caff 2"
  await model.navigator.settled()
  let row = try #require(model.navigator.selected)
  #expect(row.provider == "extension:caffeinate" && row.keywordArgument?.field == "hours")
  #expect(model.navigator.fieldSlots.map(\.name) == ["minutes", "seconds"])
  guard case .run(let address)? = model.navigator.returnAction?.kind else {
    Issue.record("Expected a run, got \(String(describing: model.navigator.returnAction))")
    return
  }
  #expect(address.targetID == "extension:caffeinate" && address.fields?["hours"] == "2")
  await model.finish()

  let preview = try await runBundled(
    "caffeinate", request: ProviderRequest(input: "2", fields: ["hours": "2", "minutes": "15"]))
  #expect(preview.items.map(\.title) == ["Keep Awake for 2 h 15 min"])
}
