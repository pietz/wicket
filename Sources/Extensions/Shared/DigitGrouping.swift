struct DigitGrouping {
  let primary: Int
  let secondary: Int

  init(_ locale: JSON?) {
    func size(_ key: String) -> Int? {
      guard let text = locale?[key]?.string, let value = Int(text), value > 0 else { return nil }
      return value
    }
    primary = size("groupingSize") ?? 3
    secondary = size("secondaryGroupingSize") ?? primary
  }

  func formatWhole(_ whole: Substring, separator: String) -> String {
    guard !separator.isEmpty else { return String(whole) }
    let count = whole.count
    let start = whole.first == "-" ? 1 : 0
    var result = ""
    for (offset, character) in whole.enumerated() {
      let remaining = count - offset
      if offset > start, remaining >= primary, (remaining - primary).isMultiple(of: secondary) {
        result += separator
      }
      result.append(character)
    }
    return result
  }
}
