// Wicket's Caffeinate: keeps the Mac and its display awake for a typed duration, or until turned off.
// `caff 2` and Return at the root keeps it awake for two hours. Inside the command, hours take the
// main field and Tab reaches minutes and seconds. Typing previews what Return would start, and the list
// shows whether the Mac is being kept awake, with Turn Off. Only a submitted request starts or stops it.
//
// The Mac stays awake through `/usr/bin/caffeinate`, started in a session of its own with nothing
// inherited but /dev/null. That puts it outside the request's process tree, which Wicket stops once the
// request answers, so the timer outlives the request, the panel and Wicket itself, as a timer must.
// `caffeinate` releases its assertions when it exits: at its timeout, or on SIGTERM from Turn Off or
// from a new run replacing it. The data folder keeps its pid with its start time, so a reused pid is
// never taken for it.
//
// Hours are a text field, not a number: only a text field takes the keyword's argument (`caff 2`).
// After editing, build it with `swiftc -O *.swift -o main`.
import Darwin
import Foundation

// MARK: - The duration

/// What the fields ask for: nothing yet, a number of seconds (0 for until turned off), or not a duration.
enum Draft: Equatable {
  case empty
  case seconds(Int)
  case invalid
}

func draft(hours: String, minutes: String, seconds: String) -> Draft {
  let parts = [(hours, 3600.0), (minutes, 60.0), (seconds, 1.0)].map {
    ($0.0.trimmingCharacters(in: .whitespaces), $0.1)
  }
  guard parts.contains(where: { !$0.0.isEmpty }) else { return .empty }
  var total = 0.0
  for (text, unit) in parts where !text.isEmpty {
    // Hours are typed text, so either decimal mark; the number slots always send a dot.
    guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0
    else { return .invalid }
    total += value * unit
  }
  // `caffeinate -t` takes a 32-bit count.
  guard total.rounded() <= Double(Int32.max) else { return .invalid }
  return .seconds(Int(total.rounded()))
}

/// `2 h 30 min`, `45 s`: the nonzero parts.
func span(_ seconds: Int) -> String {
  let parts = [(seconds / 3600, "h"), (seconds % 3600 / 60, "min"), (seconds % 60, "s")]
  return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " ")
}

/// Local wall-clock time in the user's format, with the weekday when it is not today.
func clock(_ time: time_t, now: time_t) -> String {
  let date = Date(timeIntervalSince1970: TimeInterval(time))
  let today = Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now)))
  return today
    ? date.formatted(.dateTime.hour().minute())
    : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

// MARK: - The keeper

/// The command line that keeps the display (`-d`) and the system (`-i`) awake, for `seconds` or until stopped.
func keepAwake(_ seconds: Int?) -> [String] {
  ["/usr/bin/caffeinate", "-d", "-i"] + (seconds.map { ["-t", String($0)] } ?? [])
}

/// The running keeper as the data folder records it.
struct Awake: Equatable {
  let pid: pid_t
  /// Kernel start time in microseconds, which tells the keeper from a later process with its pid.
  let start: UInt64
  /// When its timeout ends; nil while it runs until stopped.
  let until: time_t?
}

func startTime(of pid: pid_t) -> UInt64? {
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB
  else { return nil }
  return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

/// The recorded keeper while it still runs.
func running(in folder: String) -> Awake? {
  guard let text = try? String(contentsOfFile: folder + "/awake", encoding: .utf8) else { return nil }
  let words = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  guard words.count == 3, let pid = pid_t(words[0]), let start = UInt64(words[1]),
    let until = time_t(words[2]), startTime(of: pid) == start
  else { return nil }
  return Awake(pid: pid, start: start, until: until > 0 ? until : nil)
}

func record(_ awake: Awake?, in folder: String) -> Bool {
  let path = folder + "/awake"
  guard let awake else { return unlink(path) == 0 || errno == ENOENT }
  let line = "\(awake.pid) \(awake.start) \(awake.until ?? 0)\n"
  return (try? line.write(toFile: path, atomically: true, encoding: .utf8)) != nil
}

/// Starts `argv` in a session of its own, with stdio on /dev/null, no other descriptor inherited and
/// default signal handling, and leaves it running; nil when it could not start. An ignored or blocked
/// SIGTERM would otherwise pass from a parent to the keeper, and Turn Off could not stop it.
func detach(_ argv: [String]) -> pid_t? {
  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  var none = sigset_t()
  var all = sigset_t()
  sigemptyset(&none)
  sigfillset(&all)
  posix_spawnattr_setsigmask(&attributes, &none)
  posix_spawnattr_setsigdefault(&attributes, &all)
  posix_spawnattr_setflags(
    &attributes,
    Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  for descriptor: Int32 in 0...2 {
    posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
  }
  let words = argv.map { strdup($0) } + [nil]
  defer { for word in words { free(word) } }
  var pid: pid_t = 0
  guard posix_spawn(&pid, argv[0], &actions, &attributes, words, environ) == 0 else { return nil }
  return pid
}

// MARK: - Views

/// A row whose Return runs the named action (`start` or `stop`), or does nothing without one.
func row(_ id: String, _ title: String, _ subtitle: String, icon: String, action: String = "")
  -> String
{
  let name = action == "stop" ? "Turn Off" : "Keep Awake"
  let run = "{\"type\":\"run\",\"title\":\(quoted(name)),\"action\":\(quoted(action))}"
  return "{\"id\":\(quoted(id)),\"title\":\(quoted(title)),\"subtitle\":\(quoted(subtitle)),"
    + "\"icon\":\(quoted(icon)),\"actions\":[\(action.isEmpty ? "" : run)]}"
}

/// Whether the Mac is being kept awake, with Turn Off, which the footer names as Return.
func status(_ awake: Awake, now: time_t) -> String {
  guard let until = awake.until else {
    return row(
      "awake", "Awake until you turn it off", "No timer", icon: "cup.and.saucer.fill", action: "stop")
  }
  // Whole minutes left, rounded up, and seconds only in the last minute.
  let left = max(0, Int(until - now))
  let remaining = left < 60 ? span(max(left, 1)) : span((left + 59) / 60 * 60)
  return row(
    "awake", "Awake until \(clock(until, now: now))", "\(remaining) left",
    icon: "cup.and.saucer.fill", action: "stop")
}

/// What Return would start with the fields as they are.
func start(_ draft: Draft, now: time_t) -> String {
  switch draft {
  case .seconds(let seconds) where seconds > 0:
    return row(
      "start", "Keep Awake for \(span(seconds))", "Until \(clock(now + seconds, now: now))",
      icon: "cup.and.saucer", action: "start")
  case .invalid:
    return row(
      "invalid", "Enter hours, minutes and seconds as numbers", "For example 1.5 hours",
      icon: "exclamationmark.triangle")
  default:
    return row("start", "Keep Awake", "Until you turn it off", icon: "cup.and.saucer", action: "start")
  }
}

// MARK: - The request

/// The answer to a request; a submitted Keep Awake or Turn Off acts first. `keeper` is the command line
/// for a duration, so tests keep the Mac's sleep alone.
func answer(
  _ request: JSON?, folder: String, now: time_t = time(nil), keeper: (Int?) -> [String] = keepAwake
) -> String {
  let fields = request?["fields"]
  let typed = draft(
    hours: fields?["hours"]?.string ?? request?["input"]?.string ?? "",
    minutes: fields?["minutes"]?.string ?? "", seconds: fields?["seconds"]?.string ?? "")
  let action = request?["action"]?.string
  var awake = running(in: folder)
  var rows: [String] = []
  if case .bool(true)? = request?["submitted"] {
    // A row's Keep Awake, or the search bar submitted with a duration (`caff 2` at the root); entering
    // the command with nothing typed only shows the state.
    let startFor: Int?? =
      switch (action, typed) {
      case ("start", .empty): .some(nil)
      case ("start", .seconds(let seconds)), (nil, .seconds(let seconds)): .some(seconds > 0 ? seconds : nil)
      default: nil
      }
    if let seconds = startFor {
      let argv = keeper(seconds)
      if let pid = detach(argv), let begun = startTime(of: pid) {
        let started = Awake(pid: pid, start: begun, until: seconds.map { now + $0 })
        if record(started, in: folder) {
          // The new keeper took over before the old one goes, so the Mac never sleeps in between.
          if let awake { kill(awake.pid, SIGTERM) }
          return "{\"items\":[\(status(started, now: now))]}"
        }
        kill(pid, SIGTERM)
      }
      rows.append(row("failed", "Could not keep your Mac awake", argv[0], icon: "exclamationmark.triangle"))
    } else if action == "stop", let current = awake {
      kill(current.pid, SIGTERM)
      _ = record(nil, in: folder)
      awake = nil
    }
  }
  let preview = start(typed, now: now)
  // What was typed leads; with nothing typed, the state does.
  if let awake {
    if case .seconds(let seconds) = typed, seconds > 0 {
      rows += [preview, status(awake, now: now)]
    } else {
      rows += [status(awake, now: now), preview]
    }
  } else {
    rows.append(preview)
  }
  return "{\"items\":[" + rows.joined(separator: ",") + "]}"
}

print(
  answer(
    JSON.standardInput(),
    folder: ProcessInfo.processInfo.environment["WICKET_DATA_DIR"] ?? FileManager.default.currentDirectoryPath
  ))
