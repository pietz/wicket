import Foundation

extension Page {
  struct Field: Equatable, Sendable {
    let name: String
    let label: String
    let control: Control
    let action: String?
    var value: String
    var id: String { "#field:" + name }

    enum Control: Equatable, Sendable {
      case toggle
      case slider(min: Double, max: Double, step: Double)
      case choice([Option])
    }
    struct Option: Equatable, Sendable {
      let value: String
      let label: String
    }
    struct Change: Equatable, Sendable {
      enum Phase: String, Sendable { case preview, commit }
      let name: String
      let value: String
      let phase: Phase
    }

    init?(_ attributes: [(String, String)]) {
      let values = Dictionary(attributes, uniquingKeysWith: { first, _ in first })
      guard let name = values["name"],
        name.wholeMatch(of: /[A-Za-z][A-Za-z0-9_.-]{0,63}/) != nil,
        let kind = values["type"].flatMap(ExtensionManifest.Field.Kind.init)
      else { return nil }
      self.name = name
      label = values["label"].flatMap { $0.isEmpty ? nil : $0 } ?? name
      switch values["act"] {
      case nil, "false": action = nil
      case "true": action = "set-" + name
      case let named?:
        guard let decoded = named.removingPercentEncoding,
          !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        action = decoded
      }
      let initial: String
      switch kind {
      case .text: return nil
      case .bool:
        control = .toggle
        initial = "false"
      case .number:
        guard let min = values["min"].flatMap(Self.number), let max = values["max"].flatMap(Self.number),
          let step = Self.number(values["step"] ?? "1"), min < max, step > 0,
          (max - min).isFinite, min + step > min
        else { return nil }
        control = .slider(min: min, max: max, step: step)
        initial = Self.wire(min)
      case .choice:
        guard let encoded = values["options"] else { return nil }
        let pairs = encoded.split(separator: "&", omittingEmptySubsequences: false)
        let options = pairs.compactMap {
          pair -> Option? in
          let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          guard parts.count == 2, let value = parts[0].removingPercentEncoding, !value.isEmpty,
            let label = parts[1].removingPercentEncoding, !label.isEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
          else { return nil }
          return Option(value: value, label: label)
        }
        guard let first = options.first,
          options.count == pairs.count,
          Set(options.map(\.value)).count == options.count
        else { return nil }
        control = .choice(options)
        initial = first.value
      }
      value = initial
      guard let canonical = canonical(values["value"] ?? initial) else { return nil }
      value = canonical
    }

    func canonical(_ value: String) -> String? {
      switch control {
      case .toggle:
        return value == "true" || value == "false" ? value : nil
      case .choice(let options):
        return options.contains { $0.value == value } ? value : nil
      case .slider(let min, let max, let step):
        guard let number = Self.number(value), (min...max).contains(number) else { return nil }
        let index = (number - min) / step
        // WebKit sends a decimal. Allow floating point rounding when checking its step grid.
        let tolerance = Swift.min(0.000_001, Swift.max(index.ulp, (min.ulp + number.ulp) / step) * 4)
        guard abs(index - index.rounded()) <= tolerance else { return nil }
        return Self.wire(number)
      }
    }

    func nextValue() -> String {
      switch control {
      case .toggle: return value == "true" ? "false" : "true"
      case .choice(let options):
        return options[((options.firstIndex { $0.value == value } ?? 0) + 1) % options.count].value
      case .slider(let min, let max, let step):
        let current = Self.number(value) ?? min
        let locale = Locale(identifier: "en_US_POSIX")
        let next: Double
        if let decimal = Decimal(string: value, locale: locale),
          let increment = Decimal(string: String(step), locale: locale),
          let sum = Self.number(NSDecimalNumber(decimal: decimal + increment).stringValue)
        {
          next = sum
        } else {
          next = current + step
        }
        if next.isFinite, next <= max + max.ulp * 2, next > current,
          let value = canonical(Self.wire(Swift.min(next, max)))
        {
          return value
        }
        return Self.wire(min)
      }
    }

    private static func number(_ value: String) -> Double? {
      guard value.wholeMatch(of: /[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/) != nil,
        let number = Double(value), number.isFinite
      else { return nil }
      return number
    }

    private static func wire(_ number: Double) -> String {
      if number == 0 { return "0" }
      let parts = String(abs(number)).split(separator: "e")
      let mantissa = parts[0].split(separator: ".")
      let whole = String(mantissa[0])
      let fraction = mantissa.count == 2 && mantissa[1] != "0" ? String(mantissa[1]) : ""
      let digits = whole + fraction
      let position = whole.count + (parts.count == 2 ? Int(parts[1])! : 0)
      let sign = number < 0 ? "-" : ""
      if position <= 0 {
        return sign + "0." + String(repeating: "0", count: -position) + digits
      }
      if position >= digits.count {
        return sign + digits + String(repeating: "0", count: position - digits.count)
      }
      return sign + digits.prefix(position) + "." + digits.dropFirst(position)
    }
  }
}
