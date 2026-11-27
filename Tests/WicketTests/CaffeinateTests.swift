import Foundation
import Synchronization
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

/// Reaps a stand-in keeper this test process started, once it was told to stop; one still running after
/// two seconds is killed and reported as not ended.
private func ended(_ pid: pid_t) -> Bool {
  var status: Int32 = 0
  for _ in 0..<200 {
    if waitpid(pid, &status, WNOHANG) == pid { return true }
    usleep(10_000)
  }
  kill(pid, SIGKILL)
  _ = waitpid(pid, &status, 0)
  return false
}

/// Starts a stand-in keeper and notes its pid.
private func sleeper(_ started: borrowing Mutex<[pid_t]>) -> pid_t? {
  let pid = detach(["/bin/sleep", "600"])
  if let pid { started.withLock { $0.append(pid) } }
  return pid
}

/// Every keeper the runs started has ended, but the recorded one, which is stopped and reaped here.
private func onlyTheRecordedKeeperRuns(_ started: [pid_t], in folder: URL) -> Bool {
  let recorded = running(in: folder.path)
  let others = started.filter { $0 != recorded?.pid }.map(ended)
  if let recorded {
    kill(recorded.pid, SIGTERM)
    guard ended(recorded.pid) else { return false }
  }
  return others.allSatisfy { $0 } && (recorded.map { started.contains($0.pid) } ?? true)
}

@Test func theKeeperHoldsTheDisplayAndSystemAwakeForTheDuration() {
  #expect(keepAwake(5400) == ["/usr/bin/caffeinate", "-d", "-i", "-t", "5400"])
  #expect(keepAwake(nil) == ["/usr/bin/caffeinate", "-d", "-i"])
}

@Test(arguments: [
  ("2", "", Draft.seconds(7200)), ("1,5", "30", .seconds(7200)), (" 0.5 ", "", .seconds(1800)),
  ("", "", .empty), ("0", "", .seconds(0)), ("-1", "", .invalid), ("two", "", .invalid),
  ("", "abc", .invalid), ("1e9", "", .invalid), ("", "0.01", .seconds(1)), ("0.0001", "", .seconds(1)),
])
func durationsComeFromHoursMinutesAndSeconds(hours: String, minutes: String, expected: Draft) {
  #expect(draft(hours: hours, minutes: minutes, seconds: "") == expected)
}

@Test func onlyASubmittedChoiceStartsReplacesOrStopsTheKeeper() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let now = Now.current
  let started = Mutex<[pid_t]>([])
  var asked: [Int?] = []
  func answered(_ request: JSON) -> String {
    answer(request, folder: folder.path, now: now) {
      asked.append($0)
      return sleeper(started)
    }
  }

  // Entering, typing and links only describe; a typed duration leads with what Return starts.
  var shown = try rows(answered(request()))
  #expect(shown.map(\.title) == ["Keep Awake"] && shown[0].subtitle == "Until you turn it off")
  #expect(shown[0].actions.map(\.kind) == [.run(Address(action: "start"))])
  shown = try rows(answered(request(hours: "2", minutes: "30")))
  #expect(shown.map(\.title) == ["Keep Awake for 2 h 30 min"])
  #expect(shown[0].subtitle == "Until " + clock(now.wall + 9000, now: now.wall))
  _ = answered(request(submitted: true))
  _ = answered(request(hours: "x", submitted: true, action: "start"))
  #expect(asked.isEmpty && running(in: folder.path) == nil)

  // `caff 2` at the root: submitted with hours and no action. The keeper leaves this session. Return on
  // the selected state does nothing, so a second Return cannot undo the first; Turn Off is its own row.
  shown = try rows(answered(request(hours: "2", submitted: true)))
  let first = try #require(running(in: folder.path))
  #expect(asked == [7200] && first.until == now.after(7200))
  #expect(getsid(first.pid) == first.pid && getpgid(first.pid) == first.pid)
  #expect(shown.map(\.title) == ["Awake until " + clock(now.wall + 7200, now: now.wall), "Turn Off"])
  #expect(shown[0].subtitle == "2 h left" && shown[0].actions.isEmpty)
  #expect(shown[1].actions.map(\.kind) == [.run(Address(action: "stop"))])

  // Anything typed leads while one runs, even a zero or a typo; nothing typed shows the state first,
  // with Turn Off on it.
  for typed in [request(minutes: "5"), request(hours: "0")] {
    #expect(try rows(answered(typed)).map(\.id) == ["start", "awake"])
  }
  #expect(try rows(answered(request(hours: "2h"))).map(\.id) == ["invalid", "awake"])
  shown = try rows(answered(request()))
  #expect(shown.map(\.id) == ["awake", "start"])
  #expect(shown[0].actions.map(\.kind) == [.run(Address(action: "stop"))])

  // Keep Awake with nothing typed replaces it with one that runs until turned off.
  shown = try rows(answered(request(submitted: true, action: "start")))
  let second = try #require(running(in: folder.path))
  #expect(asked == [7200, nil] && second.until == nil && second.pid != first.pid)
  #expect(ended(first.pid))
  #expect(shown.map(\.title) == ["Awake until you turn it off", "Turn Off"])

  // Turn Off stops it and forgets it.
  shown = try rows(answered(request(submitted: true, action: "stop")))
  #expect(ended(second.pid) && running(in: folder.path) == nil)
  #expect(shown.map(\.title) == ["Keep Awake"] && asked.count == 2)
  #expect(started.withLock { $0 } == [first.pid, second.pid])
}

/// `caffeinate -t` counts uptime, which stops while the Mac sleeps, so the finish time moves with it.
@Test func theDeadlineCountsUptimeAndShowsAsLocalTime() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let begun = Now(wall: 1_800_000_000, uptime: 5_000_000_000_000)
  _ = answer(request(hours: "2", submitted: true), folder: folder.path, now: begun) { _ in
    detach(["/bin/sleep", "600"])
  }
  let awake = try #require(running(in: folder.path))
  defer {
    kill(awake.pid, SIGTERM)
    _ = ended(awake.pid)
  }
  #expect(awake.until == 5_000_000_000_000 + 7_200_000_000_000)

  // Half an hour awake, then an hour asleep: uptime moved 30 min, the wall clock 90, so the timer now
  // ends an hour later than it first showed.
  let later = Now(wall: begun.wall + 5400, uptime: begun.after(1800))
  let state = try rows(answer(request(), folder: folder.path, now: later))[0]
  #expect(state.title == "Awake until " + clock(begun.wall + 10800, now: later.wall))
  #expect(state.subtitle == "1 h 30 min left")
  #expect(later.left(awake.until!) == 5400 && later.left(begun.uptime) == 0)
}

/// The panel and a headless run at once: each start replaces the other, so one keeper runs and the
/// record names it; a Turn Off racing a start never leaves a keeper the record has lost.
@Test func overlappingRequestsLeaveOneRecordedKeeper() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let started = Mutex<[pid_t]>([])
  func overlapping(_ requests: [JSON]) {
    DispatchQueue.concurrentPerform(iterations: requests.count) { index in
      _ = answer(requests[index], folder: folder.path) { _ in
        let pid = sleeper(started)
        // Holds the request between starting its keeper and recording it, where the other one reads.
        usleep(100_000)
        return pid
      }
    }
  }

  overlapping([request(hours: "1", submitted: true), request(hours: "2", submitted: true)])
  #expect(started.withLock { $0.count } == 2)
  #expect(onlyTheRecordedKeeperRuns(started.withLock { $0 }, in: folder))

  started.withLock { $0 = [] }
  _ = answer(request(hours: "1", submitted: true), folder: folder.path) { _ in sleeper(started) }
  overlapping([request(hours: "2", submitted: true), request(submitted: true, action: "stop")])
  #expect(onlyTheRecordedKeeperRuns(started.withLock { $0 }, in: folder))
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

/// What a submitted `caff 2` answers, recorded for the panel capture with a stand-in keeper that is
/// stopped again.
func recordedCaffeinateConfirmation() throws -> String {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let started = Mutex<[pid_t]>([])
  let shown = answer(request(hours: "2", submitted: true), folder: folder.path) { _ in sleeper(started) }
  #expect(onlyTheRecordedKeeperRuns(started.withLock { $0 }, in: folder))
  return shown
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
