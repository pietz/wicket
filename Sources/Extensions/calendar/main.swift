// Rebuild a copy with swiftc -O *.swift -o main.
import Foundation
import os

let request = JSON.standardInput()
let now = Date()
let local = Calendar.autoupdatingCurrent
let started = ContinuousClock.now
let snapshot = EventKitReader.snapshot(in: CalendarLayout(request).window(now: now, calendar: local))
if case .loaded(let calendars, let events) = snapshot {
  let elapsed = (ContinuousClock.now - started).components
  let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
  Logger(subsystem: "app.wicket", category: "calendar").info(
    "Read \(events.count) events from \(calendars.count) calendars in \(milliseconds) ms")
}
do {
  print(try calendarView(request, snapshot: snapshot, now: now, calendar: local))
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
