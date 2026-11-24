import Foundation

extension Page {
  struct Control: Equatable, Sendable {
    let definition: Field
    let control: Kind
    var name: String { definition.name }
    var label: String { definition.title }
    let action: String?
    var value: String
    var id: String { "#field:" + name }

    enum Kind: Equatable, Sendable {
      case toggle
      case slider(min: Double, max: Double, step: Double)
      case choice([Field.Option])
    }
    struct Change: Equatable, Sendable {
      enum Phase: String, Sendable { case preview, commit }
      let name: String
      let value: String
      let phase: Phase
    }

    init?(_ field: Field) {
      guard field.name.wholeMatch(of: /[A-Za-z][A-Za-z0-9_.-]{0,63}/) != nil else { return nil }
      var field = field
      if field.type == .number, field.step == nil { field.step = 1 }
      guard field.valid else { return nil }
      switch field.action {
      case nil, .automatic(false): action = nil
      case .automatic(true): action = "set-" + field.name
      case .named(let name):
        guard !name.allSatisfy(\.isWhitespace) else { return nil }
        action = name
      }
      let initial: String
      switch field.type {
      case .text: return nil
      case .bool:
        control = .toggle
        initial = "false"
      case .number:
        guard let min = field.min, let max = field.max, let step = field.step else { return nil }
        control = .slider(min: min, max: max, step: step)
        initial = Field.wire(min)
      case .choice:
        guard let options = field.options, let first = options.first,
          !options.contains(where: {
            $0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
          })
        else { return nil }
        control = .choice(options)
        initial = first.value
      }
      definition = field
      guard let canonical = field.canonical(field.value ?? field.default ?? initial) else { return nil }
      value = canonical
    }

    func nextValue() -> String {
      switch control {
      case .toggle: return value == "true" ? "false" : "true"
      case .choice(let options):
        return options[((options.firstIndex { $0.value == value } ?? 0) + 1) % options.count].value
      case .slider(let min, let max, let step):
        let current = Field.number(value) ?? min
        let locale = Locale(identifier: "en_US_POSIX")
        let next: Double
        if let decimal = Decimal(string: value, locale: locale),
          let increment = Decimal(string: String(step), locale: locale),
          let sum = Field.number(NSDecimalNumber(decimal: decimal + increment).stringValue)
        {
          next = sum
        } else {
          next = current + step
        }
        if next.isFinite, next <= max + max.ulp * 2, next > current,
          let value = definition.canonical(Field.wire(Swift.min(next, max)))
        {
          return value
        }
        return Field.wire(min)
      }
    }

  }
}
