import Darwin

private let byteLimit = 128 * 1024

func environment(_ key: String) -> String? {
  getenv(key).flatMap { String(validatingCString: $0) }
}

private func readBytes(_ file: Int32) -> [UInt8]? {
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = read(file, &buffer, buffer.count)
    if count < 0, errno == EINTR { continue }
    guard count >= 0, bytes.count + count <= byteLimit else { return nil }
    if count == 0 { return bytes }
    bytes.append(contentsOf: buffer.prefix(count))
  }
}

func readRatesFile(_ path: String) -> [UInt8]? {
  let file = open(path, O_RDONLY | O_NONBLOCK)
  guard file >= 0 else { return nil }
  defer { close(file) }
  var info = stat()
  guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= byteLimit else {
    return nil
  }
  return readBytes(file)
}

private func stamp(_ time: time_t, format: String) -> String {
  var time = time
  var utc = tm()
  gmtime_r(&time, &utc)
  var buffer = [CChar](repeating: 0, count: 32)
  let count = strftime(&buffer, buffer.count, format, &utc)
  return String(decoding: buffer.prefix(count).map(UInt8.init), as: UTF8.self)
}

private func observation(_ day: String) -> time_t? {
  let parts = day.split(separator: "-", omittingEmptySubsequences: false)
  guard parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.allSatisfy(digit) }),
    let year = Int32(parts[0]), year > 0, let month = Int32(parts[1]), let date = Int32(parts[2])
  else { return nil }
  var utc = tm()
  utc.tm_year = year - 1900
  utc.tm_mon = month - 1
  utc.tm_mday = date
  let time = timegm(&utc)
  return stamp(time, format: "%Y-%m-%d") == day ? time : nil
}

private func rate(_ text: String) -> Double? {
  guard text.allSatisfy({ digit($0) || ".eE+-".contains($0) }),
    let value = Double(text), value.isFinite, value > 0
  else { return nil }
  return value
}

struct RateSnapshot {
  static let ecb = "ECB reference"
  let label: String
  let base: String
  let date: String
  let rates: [String: Double]
  let checked: time_t?
  private let observed: time_t

  init?(
    label: String, base: String, date: String, rates: [String: Double], checked: time_t?,
    currencies: [String: Int]
  ) {
    guard label.contains(where: { !$0.isWhitespace }), label.utf8.count <= 160,
      label.unicodeScalars.allSatisfy({ $0.value >= 32 }), currencies[base] != nil,
      let day = observation(date), !rates.isEmpty, rates.keys.allSatisfy({ currencies[$0] != nil }),
      rates[base] == nil || rates[base] == 1,
      checked.map({ $0 >= day }) ?? true
    else { return nil }
    self.label = label
    self.base = base
    self.date = date
    self.rates = rates.merging([base: 1]) { existing, _ in existing }
    self.checked = checked
    observed = day
  }

  init?(json bytes: [UInt8], network: Bool, currencies: [String: Int], now: time_t) {
    var at = 0
    guard let json = JSON.read(bytes, &at), bytes[at...].allSatisfy({ [9, 10, 13, 32].contains($0) }),
      case .number("1")? = json["schemaVersion"], let label = json["sourceLabel"]?.string,
      let base = json["base"]?.string, let date = json["observedOn"]?.string,
      case .object(let entries)? = json["rates"]
    else { return nil }
    var checked: time_t?
    if network {
      guard case .number(let text)? = json["checkedAt"], let timestamp = time_t(text), timestamp <= now,
        base == "EUR", label == Self.ecb, entries.keys.contains(where: { $0 != base })
      else { return nil }
      checked = timestamp
    }
    var rates: [String: Double] = [:]
    for (code, entry) in entries {
      guard let text = entry.string, let value = rate(text) else { return nil }
      rates[code] = value
    }
    self.init(label: label, base: base, date: date, rates: rates, checked: checked, currencies: currencies)
  }

  func stale(at now: time_t) -> Bool {
    checked.map { difftime(now, $0) > 2 * 86_400 } ?? false
  }

  func status(at now: time_t) -> String {
    let days = Int(difftime(now, observed) / 86_400)
    let source = checked == nil ? "Fixed · " + label : label
    return source + " · " + date + (days > 30 ? " · \(days) days old" : "")
      + (stale(at: now) ? " · Stale" : "")
  }

  var lastCheck: String? { checked.map { stamp($0, format: "%Y-%m-%d %H:%M UTC") } }

  func save(to path: String) -> Bool {
    guard let checked else { return false }
    let entries = rates.sorted(by: { $0.key < $1.key }).map {
      quoted($0.key) + ":" + quoted(String($0.value))
    }
    let json =
      #"{"schemaVersion":1,"sourceLabel":\#(quoted(label)),"base":\#(quoted(base)),"observedOn":\#(quoted(date)),"checkedAt":\#(checked),"rates":{\#(entries.joined(separator: ","))}}"#
    // Create in the same directory, so a cancelled refresh cannot leave a partial snapshot.
    var name = Array((path + ".XXXXXX").utf8CString)
    let file = mkstemp(&name)
    guard file >= 0 else { return false }
    let temporary = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    defer { unlink(temporary) }
    let bytes = Array(json.utf8)
    let written = bytes.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
    let closed = close(file)
    return written == bytes.count && closed == 0 && rename(temporary, path) == 0
  }

  /// The ECB feed has one dated Cube containing self-closing currency Cubes.
  static func ecbXML(_ bytes: [UInt8], at now: time_t, currencies: [String: Int]) -> Self? {
    guard let xml = String(validating: bytes, as: UTF8.self),
      xml.reversed().drop(while: \.isWhitespace).starts(with: "</gesmes:Envelope>".reversed())
    else { return nil }
    func attribute(_ name: String, in text: inout Substring) -> String? {
      guard text.first?.isWhitespace == true else { return nil }
      text = text.drop(while: \.isWhitespace)
      guard text.starts(with: name) else { return nil }
      text = text.dropFirst(name.count).drop(while: \.isWhitespace)
      guard text.first == "=" else { return nil }
      text = text.dropFirst().drop(while: \.isWhitespace)
      guard let quote = text.first, quote == "'" || quote == "\"",
        let end = text.dropFirst().firstIndex(of: quote)
      else { return nil }
      let value = String(text.dropFirst()[..<end])
      text = text[text.index(after: end)...]
      return value
    }

    var date: String?
    var rates: [String: Double] = [:]
    var depth = 0
    var closed = false
    for part in xml.split(separator: "<") {
      guard let end = part.firstIndex(of: ">") else { continue }
      let tag = part[..<end]
      guard tag.hasPrefix("Cube") || tag == "/Cube" else { continue }
      if tag == "Cube", depth == 0, !closed {
        depth = 1
      } else if tag == "/Cube", depth > 0 {
        depth -= 1
        closed = depth == 0
      } else {
        var attributes = tag.dropFirst(4)
        if depth == 1, date == nil, let day = attribute("time", in: &attributes),
          attributes.allSatisfy(\.isWhitespace)
        {
          date = day
          depth = 2
        } else if depth == 2, let code = attribute("currency", in: &attributes), code != "EUR",
          rates[code] == nil, let text = attribute("rate", in: &attributes), let value = rate(text),
          attributes.drop(while: \.isWhitespace) == "/"
        {
          rates[code] = value
        } else {
          return nil
        }
      }
    }
    guard let date, closed else { return nil }
    return Self(label: ecb, base: "EUR", date: date, rates: rates, checked: now, currencies: currencies)
  }
}

func downloadRates() -> [UInt8]? {
  let url =
    environment("WICKET_CONVERT_RATES_URL")
    ?? "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
  let arguments = [
    "/usr/bin/curl", "-q", "--globoff", "--fail", "--silent", "--max-time", "5",
    "--max-filesize", String(byteLimit), "--proto", "=http,https", "--url", url,
  ]
  var descriptors: [Int32] = [-1, -1]
  guard pipe(&descriptors) == 0 else { return nil }
  let readEnd = descriptors[0]
  let writeEnd = descriptors[1]
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
  posix_spawn_file_actions_addclose(&actions, readEnd)
  posix_spawn_file_actions_addclose(&actions, writeEnd)
  var argv = arguments.map { strdup($0) } + [nil]
  defer {
    for argument in argv.dropLast() { free(argument) }
  }
  var pid: pid_t = 0
  let spawned = posix_spawn(&pid, arguments[0], &actions, nil, &argv, environ)
  close(writeEnd)
  guard spawned == 0 else {
    close(readEnd)
    return nil
  }
  let bytes = readBytes(readEnd)
  close(readEnd)
  var status: Int32 = 0
  var waited: pid_t
  repeat {
    waited = waitpid(pid, &status, 0)
  } while waited == -1 && errno == EINTR
  return waited == pid && status == 0 ? bytes : nil
}
