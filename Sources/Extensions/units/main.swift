// Rebuild a copy with swiftc -O *.swift -o main.
import Foundation

let request = JSON.standardInput()
let marks = NumberMarks(request?["locale"])
let settings = request?["settings"]
let input = request?["input"]?.string ?? ""

func conversion() async -> String {
  guard let quantity = Quantity(input, marks: marks) else { return #"{"items":[]}"# }
  let value: Double
  let unit: String
  let currency: Bool
  var stale = false
  if let result = quantity.unitResult {
    (value, unit) = result
    currency = false
  } else {
    guard quantity.hasCurrencyToken else { return #"{"items":[]}"# }
    let home = settings?["homeCurrency"]?.string ?? "USD"
    let source = currencyCode(quantity.source, home: home)
    let target = quantity.target.map { currencyCode($0, home: home) } ?? home
    guard currencies.contains(source), currencies.contains(target) else { return #"{"items":[]}"# }
    let directory = ProcessInfo.processInfo.environment["WICKET_DATA_DIR"].map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    guard let rate = await exchangeRate(from: source, to: target, in: directory) else {
      let pair = quoted("\(source) → \(target)")
      return
        #"{"items":[{"id":"rates-unavailable","title":"Exchange rate unavailable","subtitle":\#(pair),"actions":[]}]}"#
    }
    value = quantity.amount * rate.value
    unit = target
    currency = true
    stale = rate.stale
  }
  guard value.isFinite else { return #"{"items":[]}"# }

  let decimals = Int(settings?["decimals"]?.string ?? "").flatMap { (0...15).contains($0) ? $0 : nil } ?? 2
  let number = marks.format(value, places: decimals)
  let displayed = currency ? marks.group(number) : number
  let includeUnit = settings?["includeUnit"]?.string == "true"
  let title = displayed + " " + unit
  let text = includeUnit ? number + " " + unit : number
  let subtitle = (stale ? "Cached rate · " : "") + (includeUnit ? "Copy conversion" : "Copy value")
  let icon = currency ? "banknote" : "ruler"
  return
    #"{"items":[{"id":"result","title":\#(quoted(title)),"subtitle":\#(quoted(subtitle)),"icon":\#(quoted(icon)),"prominent":true,"actions":[{"type":"copy","text":\#(quoted(text))}]}]}"#
}

print(await conversion())
