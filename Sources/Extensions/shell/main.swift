// Wicket's Shell: `> command` at the root offers to run a command; Return runs it in Wicket and shows its
// output as it comes, and the next command typed into Shell runs as a follow-up in the folder the last
// one left. Run in Terminal hands a command to the default terminal instead.
//
// Nothing runs on a request the user did not choose: the root row and links only describe the command.
// A chosen request runs `$SHELL -l -c` with stdin from /dev/null and prints a view per line as the output
// grows, at most every 100 ms (views over time, in the extension contract). The session (its folder and
// last commands with their output) is a small file in the user's temporary folder, like the window
// commands' moves: a bundled extension's own folder is inside the signed app.
//
// Plain Swift with Darwin, without Foundation, which would cost about 10 ms per process: the root row
// runs on every keystroke that starts with `>`. After editing, build it with `swiftc -O main.swift -o main`.
import Darwin

// MARK: - JSON, minimal

/// What the program reads of a JSON value: strings, booleans, objects and arrays. Anything else is
/// `other`.
enum JSON {
  case string(String)
  case bool(Bool)
  case object([String: JSON])
  case array([JSON])
  case other

  subscript(key: String) -> JSON? {
    if case .object(let members) = self { members[key] } else { nil }
  }
  var string: String? {
    if case .string(let text) = self { text } else { nil }
  }
  var array: [JSON] {
    if case .array(let values) = self { values } else { [] }
  }

  /// Reads one value from the UTF-8 at `at` and moves past it; nil for malformed JSON.
  static func read(_ bytes: [UInt8], _ at: inout Int) -> JSON? {
    func skipSpace() { while at < bytes.count, bytes[at] <= 32 { at += 1 } }
    func take(_ byte: Character) -> Bool {
      skipSpace()
      guard at < bytes.count, bytes[at] == byte.asciiValue! else { return false }
      at += 1
      return true
    }
    func hex() -> UInt32? {
      guard at + 4 <= bytes.count,
        let value = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16)
      else { return nil }
      at += 4
      return value
    }
    if take("{") {
      var members: [String: JSON] = [:]
      if take("}") { return .object(members) }
      repeat {
        guard case .string(let key)? = read(bytes, &at), take(":"), let member = read(bytes, &at) else {
          return nil
        }
        members[key] = member
      } while take(",")
      return take("}") ? .object(members) : nil
    }
    if take("[") {
      var values: [JSON] = []
      if take("]") { return .array(values) }
      repeat {
        guard let value = read(bytes, &at) else { return nil }
        values.append(value)
      } while take(",")
      return take("]") ? .array(values) : nil
    }
    guard take("\"") else {
      let start = at
      while at < bytes.count, bytes[at] > 32, !",]}".utf8.contains(bytes[at]) { at += 1 }
      let word = String(decoding: bytes[start..<at], as: UTF8.self)
      return word == "true" ? .bool(true) : word == "false" ? .bool(false) : at > start ? .other : nil
    }
    var text: [UInt8] = []
    while at < bytes.count {
      let byte = bytes[at]
      at += 1
      if byte == UInt8(ascii: "\"") { return .string(String(decoding: text, as: UTF8.self)) }
      guard byte == UInt8(ascii: "\\"), at < bytes.count else {
        text.append(byte)
        continue
      }
      let escape = bytes[at]
      at += 1
      switch escape {
      case UInt8(ascii: "b"): text.append(8)
      case UInt8(ascii: "f"): text.append(12)
      case UInt8(ascii: "n"): text.append(10)
      case UInt8(ascii: "r"): text.append(13)
      case UInt8(ascii: "t"): text.append(9)
      case UInt8(ascii: "u"):
        guard var scalar = hex() else { return nil }
        // A UTF-16 surrogate pair is one character.
        if (0xD800..<0xDC00).contains(scalar), bytes[at...].starts(with: Array("\\u".utf8)) {
          at += 2
          guard let low = hex(), (0xDC00..<0xE000).contains(low) else { return nil }
          scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
        }
        text += Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8)
      default: text.append(escape)
      }
    }
    return nil
  }
}

/// A JSON string literal.
func quoted(_ text: String) -> String {
  var out = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\t": out += "\\t"
    case _ where scalar.value < 0x20:
      out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
    default: out.unicodeScalars.append(scalar)
    }
  }
  return out + "\""
}

// MARK: - Output

/// A command's output as shown: its last 200 lines and at most 32 KiB of them, each line at most 4 KiB,
/// without terminal escapes. A carriage return starts its line again, as a progress bar redraws it.
struct Output {
  static let lineLimit = 200
  static let byteLimit = 32_768
  static let lineLength = 4096
  private(set) var lines: [[UInt8]] = []
  private(set) var line: [UInt8] = []
  /// Lines no longer shown.
  private(set) var dropped = 0
  private var bytes = 0
  private var escape = Escape.none
  private var returned = false
  private enum Escape { case none, start, csi, osc }

  mutating func append(_ data: some Sequence<UInt8>) {
    for byte in data { take(byte) }
  }
  private mutating func take(_ byte: UInt8) {
    switch escape {
    case .start:
      escape = byte == UInt8(ascii: "[") ? .csi : byte == UInt8(ascii: "]") ? .osc : .none
      return
    case .csi:
      if (0x40...0x7E).contains(byte) { escape = .none }
      return
    case .osc:
      // Ends with BEL, or ESC and a backslash, whose ESC starts an escape the backslash ends.
      if byte == 7 || byte == 27 { escape = byte == 27 ? .start : .none }
      return
    case .none: break
    }
    if returned, byte != 10 { line = [] }
    returned = false
    switch byte {
    case 27: escape = .start
    case 13: returned = true
    case 10: endLine()
    case 9, 32...126, 128...: add(byte)
    default: break
    }
  }
  private mutating func add(_ byte: UInt8) {
    if line.count < Self.lineLength {
      line.append(byte)
    } else if line.count == Self.lineLength {
      line += Array("…".utf8)
    }
  }
  private mutating func endLine() {
    lines.append(line)
    bytes += line.count + 1
    line = []
    while lines.count > Self.lineLimit || bytes > Self.byteLimit {
      bytes -= lines.removeFirst().count + 1
      dropped += 1
    }
  }
  var text: String {
    String(decoding: Array((lines + (line.isEmpty ? [] : [line])).joined(separator: [10])), as: UTF8.self)
  }
}

// MARK: - The session

/// A command of the session as it was shown. `end` is nil while it runs, and for one stopped before it
/// ended.
struct Entry: Equatable {
  var command: String
  var folder: String
  var output = ""
  var dropped = 0
  var end: String?
}

/// The folder the next command runs in and the last commands, oldest first.
struct Session: Equatable {
  var folder: String
  var entries: [Entry] = []
  /// The commands a page shows: the one running and five before it.
  static let kept = 6

  init(folder: String, entries: [Entry] = []) {
    self.folder = folder
    self.entries = entries
  }
  init?(_ bytes: [UInt8]) {
    var at = 0
    guard let value = JSON.read(bytes, &at), let folder = value["folder"]?.string else { return nil }
    self.folder = folder
    entries =
      value["entries"]?.array.compactMap { entry in
        guard let command = entry["command"]?.string, let folder = entry["folder"]?.string else { return nil }
        return Entry(
          command: command, folder: folder, output: entry["output"]?.string ?? "",
          dropped: entry["dropped"]?.string.flatMap { Int($0) } ?? 0, end: entry["end"]?.string)
      } ?? []
  }
  var json: String {
    let entries = entries.map { entry in
      "{\"command\":\(quoted(entry.command)),\"folder\":\(quoted(entry.folder)),\"output\":\(quoted(entry.output)),\"dropped\":\"\(entry.dropped)\""
        + (entry.end.map { ",\"end\":" + quoted($0) } ?? "") + "}"
    }
    return "{\"folder\":\(quoted(folder)),\"entries\":[" + entries.joined(separator: ",") + "]}"
  }
}

// Functions, not stored globals: a test of the functions here never runs this file's top-level code,
// which is what sets a global.

/// The user's temporary folder: `TMPDIR`, which macOS sets for every app, else the system's answer.
func temporaryFolder() -> String {
  if let folder = getenv("TMPDIR"), folder.pointee != 0 {
    var path = String(cString: folder)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
  guard length > 0 else { return "/tmp" }
  return String(String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self).dropLast())
}
func sessionFile() -> String { temporaryFolder() + "/wicket-shell-session.json" }
func homeFolder() -> String { getenv("HOME").map { String(cString: $0) } ?? "/" }

func contents(_ path: String) -> [UInt8]? {
  guard let file = fopen(path, "r") else { return nil }
  defer { fclose(file) }
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 1 << 16)
  while case let count = fread(&buffer, 1, buffer.count, file), count > 0 { bytes += buffer[0..<count] }
  return bytes
}
/// Replaces the file whole, so a reader never sees half of it.
func save(_ text: String, to path: String) {
  let partial = path + ".new"
  guard let file = fopen(partial, "w") else { return }
  fputs(text, file)
  fclose(file)
  rename(partial, path)
}
func isFolder(_ path: String) -> Bool {
  var info = stat()
  return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
}
/// A folder as the user reads it: `~` for home.
func shown(_ folder: String, home: String = homeFolder()) -> String {
  folder == home ? "~" : folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
}

// MARK: - The page

/// A fence longer than any run of backticks in the text, so nothing in it can end the code block.
func fence(_ text: String) -> String {
  var longest = 0
  var run = 0
  for character in text {
    run = character == "`" ? run + 1 : 0
    longest = max(longest, run)
  }
  return String(repeating: "`", count: max(3, longest + 1))
}
/// A tag attribute's value with its quotes, as Wicket's own pages write one.
func attribute(_ value: String) -> String {
  let value = String(value.map { $0 == "\n" ? " " : $0 }.prefix(300))
  if !value.contains("\"") { return "\"" + value + "\"" }
  if !value.contains("'") { return "'" + value + "'" }
  return "\"" + String(value.map { $0 == "\"" ? "”" : $0 }) + "\""
}
/// Each command with the folder it ran in, its output as literal text and how it ended; the newest last.
func page(_ session: Session, running: Bool, home: String = homeFolder()) -> String {
  guard !session.entries.isEmpty else {
    return
      "<row icon=\"terminal\" title=\"Type a command and press Return\" subtitle=\(attribute(shown(session.folder, home: home)))/>"
  }
  return session.entries.enumerated().map { index, entry in
    var part =
      "<row icon=\"terminal\" title=\(attribute(entry.command)) subtitle=\(attribute(shown(entry.folder, home: home)))/>"
    if entry.dropped > 0 {
      part += "\n\n*\(entry.dropped) earlier \(entry.dropped == 1 ? "line" : "lines") not shown*"
    }
    if !entry.output.isEmpty {
      let fence = fence(entry.output)
      part += "\n\n" + fence + "\n" + entry.output + "\n" + fence
    }
    let end = entry.end ?? (running && index == session.entries.count - 1 ? "Running" : "Stopped")
    let tone =
      end == "Exit 0"
      ? " tone=\"positive\""
      : end == "Running" ? "" : end == "Stopped" ? " tone=\"warning\"" : " tone=\"negative\""
    return part + "\n\n<badge label=\(attribute(end))\(tone)/>"
  }.joined(separator: "\n\n")
}
/// The page with its actions: Run in Terminal, for what is typed or else the newest command, and Copy
/// Output for the newest command's output. Only chosen requests get it, so it empties the input for the
/// next command, as a conversation's does.
func view(_ session: Session, running: Bool) -> String {
  var actions = [#"{"type":"run","title":"Run in Terminal","arguments":{"terminal":"1"}}"#]
  if let output = session.entries.last?.output, !output.isEmpty {
    actions.append(#"{"type":"copy","title":"Copy Output","text":"# + quoted(output) + "}")
  }
  return "{\"body\":\(quoted(page(session, running: running))),\"input\":\"\",\"actions\":["
    + actions.joined(separator: ",") + "]}"
}
/// What the root and links show: one row that says what Return does, and runs nothing.
func row(_ command: String) -> String {
  guard !command.isEmpty else {
    return
      #"{"items":[{"id":"shell","title":"Shell","subtitle":"Type a command after >","icon":"terminal","actions":[{"type":"run","title":"Open Shell","input":"","arguments":{"session":"new"}}]}]}"#
  }
  return
    "{\"items\":[{\"id\":\"run\",\"title\":\(quoted(command)),\"subtitle\":\"Run in Shell\",\"icon\":\"terminal\",\"actions\":["
    + "{\"type\":\"run\",\"title\":\"Run in Shell\",\"input\":\(quoted(command)),\"arguments\":{\"session\":\"new\"}},"
    + "{\"type\":\"run\",\"title\":\"Run in Terminal\",\"input\":\(quoted(command)),\"arguments\":{\"terminal\":\"1\",\"session\":\"new\"}}]}]}"
}

// MARK: - Running

/// The user's shell, or zsh, macOS's default, when `SHELL` names none.
func loginShell() -> String {
  guard let value = getenv("SHELL").map({ String(cString: $0) }), value.hasPrefix("/"),
    access(value, X_OK) == 0
  else { return "/bin/zsh" }
  return value
}
/// A word the shell reads literally.
func singleQuoted(_ text: String) -> String {
  "'" + text.split(separator: "'", omittingEmptySubsequences: false).joined(separator: #"'\''"#) + "'"
}
/// What the shell runs: the command, then the folder it ended in, so a `cd` carries over to the next.
func script(_ command: String, shell: String, folderFile: String) -> String {
  let status = shell.hasSuffix("/fish") ? "set __wicket_status $status" : "__wicket_status=$?"
  return command + "\n" + status + "\npwd > " + singleQuoted(folderFile) + "\nexit $__wicket_status\n"
}
/// A `.command` file for the default terminal: it goes to the folder, runs the command in a login shell
/// as Shell would, then stays in an interactive shell there.
func terminalScript(_ command: String, folder: String, shell: String) -> String {
  "#!/bin/sh\ncd " + singleQuoted(folder) + " || exit 1\n"
    + (command.isEmpty ? "" : singleQuoted(shell) + " -l -c " + singleQuoted(command) + "\n")
    + "exec " + singleQuoted(shell) + " -l\n"
}
/// Writes an executable file, owner only; false when it could not.
func writeExecutable(_ text: String, to path: String) -> Bool {
  let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o700)
  guard file >= 0 else { return false }
  defer { close(file) }
  let bytes = Array(text.utf8)
  return fchmod(file, 0o700) == 0 && write(file, bytes, bytes.count) == bytes.count
}

/// Starts a program with stdin from /dev/null and stdout and stderr into one pipe, in `folder`, passing
/// no other descriptor. Its pid and the pipe's read end.
func spawn(_ arguments: [String], in folder: String, environment: [String]) -> (pid_t, Int32)? {
  var pipes: [Int32] = [0, 0]
  guard pipe(&pipes) == 0 else { return nil }
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&actions, pipes[1], 1)
  posix_spawn_file_actions_adddup2(&actions, pipes[1], 2)
  posix_spawn_file_actions_addchdir(&actions, folder)
  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
  let argv = arguments.map { strdup($0) } + [nil]
  let envp = environment.map { strdup($0) } + [nil]
  defer { for pointer in argv + envp { free(pointer) } }
  var pid: pid_t = 0
  let failed = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
  close(pipes[1])
  guard failed == 0 else {
    close(pipes[0])
    return nil
  }
  return (pid, pipes[0])
}
/// Wicket's environment for the command, in its folder, and a dumb terminal where none is named, since
/// the output is no terminal.
func environment(in folder: String) -> [String] {
  var values: [String] = []
  var at: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = environ
  while let entry = at?.pointee {
    let text = String(cString: entry)
    if !text.hasPrefix("PWD="), !text.hasPrefix("OLDPWD=") { values.append(text) }
    at = at?.advanced(by: 1)
  }
  if !values.contains(where: { $0.hasPrefix("TERM=") }) { values.append("TERM=dumb") }
  return values + ["PWD=" + folder]
}
func milliseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000 }
/// How a wait status reads.
func end(_ status: Int32) -> String {
  status & 0x7F == 0 ? "Exit \((status >> 8) & 0xFF)" : "Killed by signal \(status & 0x7F)"
}
func show(_ view: String) {
  print(view)
  fflush(stdout)
}

/// Runs the session's newest command, printing the page as its output grows (at most every 100 ms) and
/// once more when it ended, and saving the session with each page, so a command stopped from Wicket
/// stays in it as far as it was seen. The folder the command ended in is the session's next one.
func run(_ session: inout Session) {
  let index = session.entries.count - 1
  let shell = loginShell()
  let folderFile = temporaryFolder() + "/wicket-shell-folder-\(getpid())"
  let arguments = [
    shell, "-l", "-c", script(session.entries[index].command, shell: shell, folderFile: folderFile),
  ]
  guard let (pid, pipe) = spawn(arguments, in: session.folder, environment: environment(in: session.folder))
  else {
    session.entries[index].end = "Could not start \(shell)"
    save(session.json, to: sessionFile())
    return show(view(session, running: false))
  }
  var output = Output()
  var buffer = [UInt8](repeating: 0, count: 1 << 16)
  var status: Int32?
  var open = true
  var changed = false
  var shownAt: UInt64?
  let started = milliseconds()
  while open {
    var poller = pollfd(fd: pipe, events: Int16(POLLIN), revents: 0)
    let ready = poll(&poller, 1, 25)
    if ready > 0 {
      let count = read(pipe, &buffer, buffer.count)
      if count > 0 {
        output.append(buffer[0..<count])
        changed = true
      } else {
        open = false
      }
    } else if ready == 0, status != nil {
      // The shell ended and a job it left in the background holds the output: Wicket stops it.
      break
    }
    if status == nil {
      var value: Int32 = 0
      if waitpid(pid, &value, WNOHANG) == pid { status = value }
    }
    if milliseconds() - (shownAt ?? started) >= 100, changed || shownAt == nil {
      session.entries[index].output = output.text
      session.entries[index].dropped = output.dropped
      save(session.json, to: sessionFile())
      show(view(session, running: true))
      shownAt = milliseconds()
      changed = false
    }
  }
  close(pipe)
  if status == nil {
    var value: Int32 = 0
    while waitpid(pid, &value, 0) == -1, errno == EINTR {}
    status = value
  }
  if let folder = contents(folderFile).map({ String(decoding: $0, as: UTF8.self) }) {
    let folder = folder.hasSuffix("\n") ? String(folder.dropLast()) : folder
    if isFolder(folder) { session.folder = folder }
  }
  unlink(folderFile)
  session.entries[index].output = output.text
  session.entries[index].dropped = output.dropped
  session.entries[index].end = end(status ?? 0)
  save(session.json, to: sessionFile())
  show(view(session, running: false))
}

/// Run in Terminal: what is typed, else the newest command, in the session's folder, through a
/// `.command` file the default terminal opens. False when it could not be handed over.
func handOver(_ command: String, folder: String) -> Bool {
  let temporary = temporaryFolder()
  let path = temporary + "/wicket-shell-\(getpid()).command"
  guard writeExecutable(terminalScript(command, folder: folder, shell: loginShell()), to: path),
    let (pid, pipe) = spawn(["/usr/bin/open", path], in: temporary, environment: environment(in: temporary))
  else { return false }
  close(pipe)
  var value: Int32 = 0
  while waitpid(pid, &value, 0) == -1, errno == EINTR {}
  return value == 0
}

// MARK: - The request

var bytes: [UInt8] = []
while let line = readLine(strippingNewline: false) { bytes += Array(line.utf8) }
var position = 0
let request = JSON.read(bytes, &position)
var command = Substring(request?["input"]?.string ?? "")
// `> ls` typed inside Shell is `ls`.
command = command.drop { $0 == " " || $0 == ">" }
while command.last == " " { command.removeLast() }
let arguments = request?["arguments"]
// Only the user's choice runs anything.
guard case .bool(true)? = request?["chosen"] else {
  show(row(String(command)))
  exit(0)
}
// Entering from the root starts a new session in the home folder; everything else continues it.
let home = homeFolder()
var session =
  arguments?["session"]?.string == "new"
  ? Session(folder: home) : contents(sessionFile()).flatMap(Session.init) ?? Session(folder: home)
if !isFolder(session.folder) { session.folder = home }
if arguments?["terminal"] != nil {
  // An empty input (the run emptied it) or the command just sent means the newest, in its folder.
  let newest = session.entries.last.flatMap { command.isEmpty || $0.command == command ? $0 : nil }
  if handOver(newest?.command ?? String(command), folder: newest?.folder ?? session.folder) {
    show(#"{"close":true}"#)
  } else {
    show(
      #"{"items":[{"id":"failed","title":"Could not open the terminal","icon":"exclamationmark.triangle","actions":[]}]}"#
    )
  }
  exit(0)
}
guard !command.isEmpty else {
  save(session.json, to: sessionFile())
  show(view(session, running: false))
  exit(0)
}
session.entries.append(Entry(command: String(command), folder: session.folder))
session.entries = Array(session.entries.suffix(Session.kept))
run(&session)
