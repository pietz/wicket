import Foundation

/// A bounded, inert block of page data. The visible marks and the table share the same parsed values.
struct Chart: Equatable {
  enum Kind: String, CaseIterable {
    case bar, share, line, area, column, rule

    var isSeries: Bool { self == .line || self == .area || self == .column }
  }

  struct Number: Equatable {
    let text: String
    let value: Double

    init?(_ text: String) {
      guard let value = Double(text), value.isFinite else { return nil }
      self.text = text
      self.value = value
    }
  }

  struct Mark: Equatable {
    let kind: Kind
    let label: String
    let points: [Number?]
    let at: String?
    let style: String?
    let stack: String?
    let tone: String?

    var value: Double? { points.first.flatMap { $0?.value } }
  }

  static let tagNames = Set(Kind.allCases.map(\.rawValue) + ["chart"])
  private static let maxPoints = 200
  let title: String
  let unit: String
  let labels: [String]
  let highlight: String?
  private(set) var marks: [Mark] = []
  var invalid = false

  init(_ tag: AnswerMarkdown.Tag) {
    let value = Self.attributes(tag)
    title = value["title"] ?? ""
    unit = value["unit"] ?? ""
    let labels = value["labels"].map(Self.parts) ?? []
    self.labels = Array(labels.prefix(Self.maxPoints))
    highlight = value["highlight"]
    invalid = labels.count > Self.maxPoints || labels.contains("")
  }

  private static func attributes(_ tag: AnswerMarkdown.Tag) -> [String: String] {
    Dictionary(tag.values.map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }) { first, _ in
      first
    }
  }

  private static func parts(_ value: String) -> [String] {
    value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  mutating func add(_ tag: AnswerMarkdown.Tag) {
    guard !tag.closing, let kind = Kind(rawValue: tag.name) else {
      invalid = true
      return
    }
    if !tag.selfClosing { invalid = true }
    let limit = kind.isSeries ? 8 : 24
    guard marks.count(where: { kind.isSeries ? $0.kind.isSeries : $0.kind == kind }) < limit else {
      invalid = true
      return
    }
    let attrs = Self.attributes(tag)
    let label = attrs[kind.isSeries ? "name" : "label"] ?? ""
    let at = kind == .rule ? attrs["at"] : nil
    let stack = kind == .column ? attrs["stack"].flatMap { $0.isEmpty ? nil : $0 } : nil
    let inputs = kind.isSeries ? attrs["values"].map(Self.parts) ?? [] : [attrs["value"] ?? ""]
    // Values beyond the labels are never plotted, so they cannot make the chart invalid either.
    let points = inputs.prefix(kind.isSeries ? min(labels.count, Self.maxPoints) : 1).map { text -> Number? in
      let number = Number(text)
      if number == nil, !text.isEmpty { invalid = true }
      if let number, number.value < 0, kind == .share || stack != nil { invalid = true }
      return number
    }
    if inputs.count > Self.maxPoints { invalid = true }
    if kind.isSeries {
      if labels.isEmpty || !points.prefix(labels.count).contains(where: { $0 != nil }) { invalid = true }
    } else if let at {
      if !labels.contains(at) || attrs["value"] != nil { invalid = true }
    } else if points.first.flatMap({ $0 }) == nil {
      invalid = true
    }
    if kind == .bar || kind == .share, label.isEmpty { invalid = true }
    let tone = attrs["tone"].flatMap { ["positive", "warning", "negative"].contains($0) ? $0 : nil }
    marks.append(
      Mark(kind: kind, label: label, points: points, at: at, style: attrs["style"], stack: stack, tone: tone))
  }

  var series: [Mark] { marks.filter { $0.kind.isSeries } }
  var bars: Bool { labels.isEmpty && !marks.isEmpty && marks.allSatisfy { $0.kind == .bar } }
  var shares: Bool { labels.isEmpty && !marks.isEmpty && marks.allSatisfy { $0.kind == .share } }
  var plot: Bool {
    !labels.isEmpty && !series.isEmpty && marks.allSatisfy { $0.kind.isSeries || $0.kind == .rule }
  }

  func highlighted(_ values: [Double]) -> Int? {
    let choice = highlight == "max" ? values.max() : highlight == "min" ? values.min() : nil
    return choice.flatMap { values.firstIndex(of: $0) }
  }

  func seriesName(_ mark: Mark, _ index: Int) -> String {
    mark.label.isEmpty ? "\(mark.kind.rawValue.capitalized) \(index + 1)" : mark.label
  }

  func withUnit(_ value: String) -> String { unit.isEmpty ? value : "\(value) \(unit)" }
  static func compact(_ value: Double) -> String {
    for (base, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "k")]
    where abs(value) >= base && abs(value) < 1e15 {
      return String(format: "%.3g", value / base) + suffix
    }
    return String(format: "%.4g", value == 0 ? 0 : value)
  }

}
