// Wicket's Shell: `> command` at the root offers to open the command in the user's default terminal, in
// the home folder; Return does, as a hidden run: the panel closes first. Wicket shows no output: the
// terminal is the place for a command that runs, asks or keeps going.
//
// Nothing runs on a request the user did not choose: the root row, typing and links only describe the
// command. A submitted request writes a `.command` file to the user's temporary folder and `open`s it, which
// hands it to the default terminal; a bundled extension's own folder is inside the signed app.
//
// Plain Swift with Darwin, without Foundation, which would cost about 10 ms per process: the root row
// runs on every keystroke that starts with `>`. After editing, build it with `swiftc -O *.swift -o main`.
import Darwin

// MARK: - Views

/// What the root, typing and links show: the command and what Return does, or a hint with nothing typed.
func row(_ command: String) -> String {
  guard !command.isEmpty else {
    return
      #"{"items":[{"id":"hint","title":"Type a command after >","subtitle":"Opens in Terminal","icon":"terminal","actions":[]}]}"#
  }
  return
    "{\"items\":[{\"id\":\"run\",\"title\":\(quoted(command)),\"subtitle\":\"Open in Terminal\",\"icon\":\"terminal\",\"actions\":["
    + "{\"type\":\"run\",\"title\":\"Open in Terminal\",\"input\":\(quoted(command)),\"hidden\":true}]}]}"
}
let failed =
  #"{"items":[{"id":"failed","title":"Could not open the terminal","icon":"exclamationmark.triangle","actions":[]}]}"#

// MARK: - The terminal

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
  // CChar is signed: a byte of a non-ASCII name is negative, so it is reinterpreted, never converted.
  let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
  return String(String(decoding: bytes, as: UTF8.self).dropLast())
}
func homeFolder() -> String { getenv("HOME").map { String(cString: $0) } ?? "/" }
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
/// A `.command` file for the default terminal: it goes to the folder, runs the command in a login shell,
/// then stays in an interactive shell there.
func terminalScript(_ command: String, folder: String, shell: String) -> String {
  "#!/bin/sh\ncd " + singleQuoted(folder) + " || exit 1\n" + singleQuoted(shell) + " -l -c "
    + singleQuoted(command) + "\nexec " + singleQuoted(shell) + " -l\n"
}
/// Writes the text to a new `wicket-shell-<random>.command` in `folder`, executable by the owner only, and
/// returns its path; nil when it could not. The name is created exclusively (`mkstemps`: `O_CREAT|O_EXCL`,
/// so an existing file or symlink is never followed or overwritten), and a partial file is removed.
func writeCommandFile(_ text: String, in folder: String) -> String? {
  var template = Array((folder + "/wicket-shell-XXXXXXXXXX.command").utf8CString)
  let file = mkstemps(&template, 8)
  guard file >= 0 else { return nil }
  let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  let bytes = Array(text.utf8)
  let written = fchmod(file, 0o700) == 0 && write(file, bytes, bytes.count) == bytes.count
  close(file)
  guard written else {
    unlink(path)
    return nil
  }
  return path
}
/// Removes the `.command` files of earlier runs once the terminal had a minute to open them: `open`
/// returns before the terminal reads the file, so a run cannot delete its own.
func sweep(_ folder: String, now: time_t = time(nil)) {
  guard let directory = opendir(folder) else { return }
  defer { closedir(directory) }
  while let entry = readdir(directory) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    let path = folder + "/" + name
    var info = stat()
    guard name.hasPrefix("wicket-shell-"), name.hasSuffix(".command"), lstat(path, &info) == 0,
      now - info.st_mtimespec.tv_sec > 60
    else { continue }
    unlink(path)
  }
}
/// Opens a file with `/usr/bin/open`, so the default app for it (the terminal, for a `.command`) runs it.
/// False when it could not.
func openFile(_ path: String) -> Bool {
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  for descriptor: Int32 in 0...2 {
    posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
  }
  let words: [String] = ["/usr/bin/open", path]
  let argv = words.map { strdup($0) } + [nil]
  defer { for pointer in argv { free(pointer) } }
  var pid: pid_t = 0
  guard posix_spawn(&pid, "/usr/bin/open", &actions, nil, argv, environ) == 0 else { return false }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) == -1, errno == EINTR {}
  return status == 0
}

// MARK: - The request

/// The answer to a request: a submitted one with a command hands it to the terminal through `open` and
/// has nothing to show; anything else only describes it.
func answer(
  _ request: JSON?, temporary: String = temporaryFolder(), open: (String) -> Bool = openFile
) -> String {
  var command = Substring(request?["input"]?.string ?? "")
  // `> ls` typed inside Shell is `ls`.
  command = command.drop { $0 == " " || $0 == ">" }
  while command.last == " " { command.removeLast() }
  // Only the user's choice runs anything.
  guard case .bool(true)? = request?["submitted"], !command.isEmpty else { return row(String(command)) }
  sweep(temporary)
  let script = terminalScript(String(command), folder: homeFolder(), shell: loginShell())
  guard let path = writeCommandFile(script, in: temporary) else { return failed }
  guard open(path) else {
    unlink(path)
    return failed
  }
  return ""
}

print(answer(JSON.standardInput()))
