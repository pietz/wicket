import Foundation

extension Page {
  struct Control: Equatable, Sendable {
    let definition: Field
    let control: Kind
    var name: String { definition.name }
    var label: String { definition.label ?? (isText ? definition.description ?? name : definition.title) }
    var isText: Bool { control == .text }
    var isDraft: Bool { isText && action == nil }
    var invalidText: String?
    var text: String { (invalidText ?? value).singleLineInput }
    var problem: String? {
      guard invalidText != nil else { return nil }
      if let text = invalidText, let number = Field.number(text),
        definition.min.map({ number >= $0 }) != false, definition.max.map({ number <= $0 }) != false,
        let step = definition.step
      {
        return "Enter a number in steps of \(Field.wire(step))."
      }
      switch (definition.min, definition.max) {
      case (let min?, let max?): return "Enter a number from \(Field.wire(min)) to \(Field.wire(max))."
      case (let min?, nil): return "Enter a number greater than or equal to \(Field.wire(min))."
      case (nil, let max?): return "Enter a number less than or equal to \(Field.wire(max))."
      case (nil, nil): return "Enter a number."
      }
    }
    let action: String?
    var value: String
    var id: String { "#field:" + name }
    var returnLabel: String {
      switch control {
      case .text: "Edit"
      case .toggle: value == "true" ? "Turn Off" : "Turn On"
      case .slider: "Next Value"
      case .choice: "Next Option"
      }
    }

    enum Kind: Equatable, Sendable {
      case text
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
      let hasSliderRange =
        if let min = field.min, let max = field.max {
          field.type == .number && (max - min) / (field.step ?? 1) <= 100 + 1e-10
        } else { false }
      if hasSliderRange { field.step = field.step ?? 1 }
      var declaration = field
      if field.type == .number, !hasSliderRange, declaration.value == "" { declaration.value = nil }
      guard declaration.valid, field.hidden != true, field.multiline != true else { return nil }
      switch field.action {
      case nil, .automatic(false): action = nil
      case .automatic(true): action = "set-" + field.name
      case .named(let name):
        guard !name.allSatisfy(\.isWhitespace) else { return nil }
        action = name
      }
      let initial: String
      switch field.type {
      case .text:
        control = .text
        initial = ""
      case .bool:
        control = .toggle
        initial = "false"
      case .number:
        if let min = field.min, let max = field.max, let step = field.step, hasSliderRange {
          control = .slider(min: min, max: max, step: step)
          initial = Field.wire(min)
        } else {
          control = .text
          initial = ""
        }
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
      value = field.value ?? field.default ?? initial
      value = canonical(value) ?? value
    }

    func canonical(_ value: String) -> String? {
      if isText, value.isEmpty {
        return action == nil ? "" : definition.default.flatMap(definition.canonical) ?? ""
      }
      return definition.canonical(value)
    }

    func steppedValue(_ delta: Int = 1, wrapping: Bool = true) -> String {
      switch control {
      case .text: return value
      case .toggle: return wrapping ? (value == "true" ? "false" : "true") : String(delta > 0)
      case .choice(let options):
        let index = (options.firstIndex { $0.value == value } ?? 0) + delta
        return options[
          wrapping
            ? (index + options.count) % options.count : Swift.min(Swift.max(index, 0), options.count - 1)
        ].value
      case .slider(let min, let max, let step):
        let index = Int((((Field.number(value) ?? min) - min) / step).rounded()) + delta
        let last = Int(((max - min) / step + 1e-10).rounded(.down))
        let next = wrapping && index > last ? 0 : Swift.min(Swift.max(index, 0), last)
        return sliderValue(at: next) ?? value
      }
    }

    func sliderValue(at index: Int) -> String? {
      guard case .slider(let min, let max, let step) = control else { return nil }
      let locale = Locale(identifier: "en_US_POSIX")
      if let start = Decimal(string: Field.wire(min), locale: locale),
        let increment = Decimal(string: Field.wire(step), locale: locale),
        let value = definition.canonical(
          NSDecimalNumber(decimal: start + Decimal(index) * increment).stringValue)
      {
        return value
      }
      return definition.canonical(Field.wire(Swift.min(max, min + Double(index) * step)))
    }
  }
}
