// Wicket's Shell: `> command` at the root offers to open the command in the selected terminal, in
// the home folder; Return does, as a hidden run: the panel closes first. Wicket shows no output: the
// terminal is the place for a command that runs, asks or keeps going.
//
// Nothing runs on a request the user did not choose: the root row, typing and links only describe the
// command. The named action writes a `.command` file to the user's temporary folder and hands it to the
// terminal with `open`; a bundled extension's own folder is inside the signed app.
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
    + "{\"type\":\"run\",\"title\":\"Open in Terminal\",\"action\":\"open-terminal\",\"fields\":{\"command\":\(quoted(command))},\"hidden\":true}]}]}"
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
/// A `.command` file for the terminal: it goes to the folder, runs the command in a login shell,
/// then stays in an interactive shell there. The command's shell is interactive too, so it reads the rc
/// file (`~/.zshrc`) where the user's aliases and functions live, as if typed at the prompt. An interactive
/// zsh hangs up its background jobs when it exits, so `NO_HUP` keeps a `command &` running past it.
func terminalScript(_ command: String, folder: String, shell: String) -> String {
  let options = shell.hasSuffix("/zsh") ? " -l -i -o NO_HUP -c " : " -l -i -c "
  return "#!/bin/sh\ncd " + singleQuoted(folder) + " || exit 1\n" + singleQuoted(shell) + options
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
func terminalBundleID(_ choice: String?) -> String? {
  switch choice {
  case "terminal": "com.apple.Terminal"
  case "iterm2": "com.googlecode.iterm2"
  case "ghostty": "com.mitchellh.ghostty"
  default: nil
  }
}

/// macOS reports whether it could hand off the file, without waiting for the terminal to finish.
func openFile(_ words: [String]) -> Bool {
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  for descriptor: Int32 in 0...2 {
    posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
  }
  let argv = words.map { strdup($0) } + [nil]
  defer { for pointer in argv { free(pointer) } }
  var pid: pid_t = 0
  guard posix_spawn(&pid, "/usr/bin/open", &actions, nil, argv, environ) == 0 else { return false }
  var status: Int32 = 0
  var result: pid_t
  repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
  return result == pid && status == 0
}

// MARK: - The request

/// The answer to a request: the submitted open-terminal action hands it to the terminal through `open` and
/// has nothing to show; anything else only describes it.
func answer(
  _ request: JSON?, temporary: String = temporaryFolder(), open: ([String]) -> Bool = openFile
) -> String {
  var command = Substring(request?["fields"]?["command"]?.string ?? request?["input"]?.string ?? "")
  // `> ls` typed inside Shell is `ls`.
  command = command.drop { $0 == " " || $0 == ">" }
  while command.last == " " { command.removeLast() }
  // Only the user's choice runs anything.
  guard case .bool(true)? = request?["submitted"], request?["action"]?.string == "open-terminal",
    !command.isEmpty
  else { return row(String(command)) }
  sweep(temporary)
  let script = terminalScript(String(command), folder: homeFolder(), shell: loginShell())
  guard let path = writeCommandFile(script, in: temporary) else { return failed }
  if let bundleID = terminalBundleID(request?["settings"]?["terminal"]?.string),
    open(["/usr/bin/open", "-b", bundleID, path])
  {
    return ""
  }
  guard open(["/usr/bin/open", path]) else {
    unlink(path)
    return failed
  }
  return ""
}

print(answer(JSON.standardInput()))
