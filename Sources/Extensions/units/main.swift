// Wicket's unit and currency converter. Local lookup uses only the standard library and Darwin.
// Rebuild a copy with swiftc -O *.swift -o main.
import Darwin

func row(
  _ id: String, _ title: String, subtitle: String? = nil, icon: String = "ruler",
  prominent: Bool = false, actions: [String] = []
) -> String {
  let secondary = subtitle.map { ",\"subtitle\":" + quoted($0) } ?? ""
  return
    #"{"id":\#(quoted(id)),"title":\#(quoted(title)),"icon":\#(quoted(icon)),"prominent":\#(prominent),"actions":[\#(actions.joined(separator: ","))]\#(secondary)}"#
}

func list(_ rows: [String]) -> String {
  #"{"items":[\#(rows.joined(separator: ","))]}"#
}

func copy(_ value: String) -> String {
  #"{"type":"copy","text":\#(quoted(value))}"#
}

func fact(_ label: String, _ value: String) -> String {
  let escaped = String(value.map { $0 == "\"" ? "”" : $0 })
  return #"<row label="\#(label)" value="\#(escaped)"/>"#
}

struct Convert {
  let marks: NumberMarks
  let input: String
  let settings: JSON?
  let details: Bool
  let submitted: Bool
  let action: String?

  init(_ request: JSON?) {
    marks = NumberMarks(request?["locale"])
    input = request?["fields"]?["conversion"]?.string ?? request?["input"]?.string ?? ""
    settings = request?["settings"]
    details = request?["fields"]?["view"]?.string == "rates"
    if case .bool(true)? = request?["submitted"] {
      submitted = true
      action = request?["action"]?.string
    } else {
      submitted = false
      action = nil
    }
  }

  func run(_ title: String, _ action: String, details: Bool) -> String {
    #"{"type":"run","title":\#(quoted(title)),"action":\#(quoted(action)),"fields":{"view":"\#(details ? "rates" : "")","conversion":\#(quoted(input))}}"#
  }

  func view() -> String {
    let rateSource = settings?["rateSource"]?.string ?? "ecb"
    let network = rateSource == "ecb"
    let quantity = Quantity(input, marks: marks)
    let refresh = network && action == "refresh-rates"
    let unit = quantity?.unitResult
    if !details, !refresh {
      if let (value, target) = unit {
        let answer = marks.format(value) + " " + target
        return list([
          row("result", answer, subtitle: "Copy conversion", prominent: true, actions: [copy(answer)])
        ])
      }
      if !input.isEmpty, quantity?.hasCurrencyToken != true {
        return list([])
      }
    }
    let help = row(
      "help",
      rateSource == "off" ? "Try 10 km in mi, 20 c in k or 2 gal to l" : "Try 10 km in mi or 100 usd to eur")
    if rateSource == "off" { return list(input.isEmpty ? [help] : []) }

    let currencies = minorUnits()
    let home = settings?["homeCurrency"]?.string ?? "USD"
    let source = quantity.map { currencyCode($0.source, home: home) }
    let target = quantity?.target.map { currencyCode($0, home: home) } ?? home
    let pair = source.flatMap { source in
      currencies[source] != nil && currencies[target] != nil ? (source, target) : nil
    }
    guard details || refresh || input.isEmpty || pair != nil else { return list([]) }

    var now = time(nil)
    let filename = environment("WICKET_DATA_DIR").map { $0 + "/rates.json" }
    var snapshot: RateSnapshot?
    var problem: String?
    if network {
      snapshot = filename.flatMap(readRatesFile).flatMap {
        RateSnapshot(json: $0, network: true, currencies: currencies, now: now)
      }
      let stale = snapshot?.stale(at: now) ?? true
      if refresh || (submitted && action == nil && input.isEmpty && !details && stale) {
        let bytes = downloadRates()
        now = time(nil)
        if let bytes, let fresh = RateSnapshot.ecbXML(bytes, at: now, currencies: currencies) {
          if let filename, fresh.save(to: filename) {
            snapshot = fresh
          } else {
            problem = "Could not save exchange rates"
          }
        } else {
          problem = "Could not download valid rates from the ECB"
        }
      }
    } else if let path = settings?["ratesFile"]?.string, !path.isEmpty {
      let resolved = path.hasPrefix("~/") ? (environment("HOME") ?? "") + String(path.dropFirst()) : path
      if let bytes = readRatesFile(resolved) {
        snapshot = RateSnapshot(json: bytes, network: false, currencies: currencies, now: now)
        if snapshot == nil { problem = "The fixed rates file is invalid" }
      } else {
        problem = "Could not read the fixed rates file"
      }
    } else {
      problem = "Set the fixed rates file in Settings"
    }

    let detailsAction = run("Rate details", "show-rates", details: true)
    let refreshAction = run("Refresh rates", "refresh-rates", details: details)
    guard let snapshot else {
      let title =
        network ? (problem == nil ? "Download exchange rates" : "Retry download") : "Rate unavailable"
      let actions = network ? [run(title, "refresh-rates", details: details)] : []
      let notice = row("rates-unavailable", title, subtitle: problem, icon: "banknote", actions: actions)
      if details {
        return page(
          ["## Rate details", fact("Rates", problem ?? "Download exchange rates to see the table")],
          actions: actions + [run("Back to conversions", "show-conversions", details: false)])
      }
      return list(input.isEmpty ? [notice, help] : [notice])
    }

    let status = snapshot.status(at: now)
    let subtitle = [status, problem].compactMap { $0 }.joined(separator: " · ")
    let unavailable = pair.flatMap { pair in
      [pair.0, pair.1].first { snapshot.rates[$0] == nil }
    }.map { network ? "ECB does not publish a rate for \($0)" : "The fixed rates file has no rate for \($0)" }
    let applied = pair.flatMap { source, target in
      snapshot.rates[source].flatMap { from in snapshot.rates[target].map { $0 / from } }
    }
    let actions = [detailsAction] + (network ? [refreshAction] : [])
    if details {
      var lines = ["## Rate details"]
      if let (source, target) = pair {
        let value = applied.flatMap { $0.isFinite ? marks.format($0) : nil }
        lines.append(
          fact("\(source) → \(target)", value.map { "1 \(source) = \($0) \(target)" } ?? "Rate unavailable"))
        if let unavailable { lines.append(fact("Coverage", unavailable)) }
      }
      lines.append(fact("Source", status))
      if let check = snapshot.lastCheck { lines.append(fact("Last successful check", check)) }
      if let problem { lines.append(fact("Refresh", problem)) }
      lines.append("## Rates per 1 \(snapshot.base)")
      let preferred = pair.map { [$0.0, $0.1] } ?? []
      let codes = preferred + snapshot.rates.keys.sorted()
      var shown: Set<String> = []
      for code in codes where shown.insert(code).inserted {
        if let value = snapshot.rates[code] { lines.append(fact(code, marks.format(value))) }
      }
      var pageActions = network ? [refreshAction] : []
      pageActions.append(run("Back to conversions", "show-conversions", details: false))
      return page(lines, actions: pageActions)
    }
    if let quantity, pair != nil {
      if let applied, let places = currencies[target] {
        let value = quantity.amount * applied
        if value.isFinite {
          let title = marks.format(value, places: places, grouped: true) + " " + target
          let text = marks.format(value, places: places) + " " + target
          return list([
            row(
              "result", title, subtitle: subtitle, icon: "banknote", prominent: true,
              actions: [copy(text)] + actions)
          ])
        }
      }
      let reason = unavailable ?? "Amount is outside the supported range"
      return list([
        row(
          "rates-unavailable", "Rate unavailable", subtitle: reason + " · " + subtitle,
          icon: "banknote", actions: actions)
      ])
    }
    return list([row("rates", "Rate details", subtitle: subtitle, icon: "banknote", actions: actions), help])
  }

  func page(_ lines: [String], actions: [String]) -> String {
    #"{"body":\#(quoted(lines.joined(separator: "\n"))),"actions":[\#(actions.joined(separator: ","))]}"#
  }
}

print(Convert(JSON.standardInput()).view())
