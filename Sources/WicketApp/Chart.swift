import Foundation

/// A bounded, inert block of page data. The visible marks and the table share the same parsed values.
struct Chart {
  private enum Kind: String, CaseIterable {
    case bar, share, line, area, column, rule

    var isSeries: Bool { self == .line || self == .area || self == .column }
  }

  private struct Number {
    let text: String
    let value: Double

    init?(_ text: String) {
      guard let value = Double(text), value.isFinite else { return nil }
      self.text = text
      self.value = value
    }
  }

  private struct Mark {
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
  private let title: String
  private let unit: String
  private let labels: [String]
  private let highlight: String?
  private var marks: [Mark] = []
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
    let points = inputs.prefix(Self.maxPoints).map { text -> Number? in
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

  private var series: [Mark] { marks.filter { $0.kind.isSeries } }
  private var bars: Bool { labels.isEmpty && !marks.isEmpty && marks.allSatisfy { $0.kind == .bar } }
  private var shares: Bool { labels.isEmpty && !marks.isEmpty && marks.allSatisfy { $0.kind == .share } }
  private var plot: Bool {
    !labels.isEmpty && !series.isEmpty && marks.allSatisfy { $0.kind.isSeries || $0.kind == .rule }
  }

  func html(pending: Bool, ordinal: Int) -> String {
    let heading = title.isEmpty ? "" : "<div class=\"chart-title\">\(Self.escape(title))</div>"
    if pending {
      return "<w-chart class=\"chart-pending\"><div class=\"chart-view\">\(heading)"
        + "<div class=\"chart-placeholder\" aria-hidden=\"true\"></div></div></w-chart>"
    }
    let data = table()
    let content: String
    let summary: String
    if !invalid, bars {
      content = barMarks()
      summary = "Bar chart comparing \(marks.count) values"
    } else if !invalid, shares, marks.contains(where: { ($0.value ?? 0) > 0 }) {
      content = shareMarks()
      summary = "Share chart showing \(marks.count) parts of a whole"
    } else if !invalid, plot {
      content = plotMarks(ordinal: ordinal)
      summary = "Chart of \(series.count) data series across \(labels.count) categories"
    } else {
      return "<w-chart class=\"chart-fallback\"><div class=\"chart-view\">\(heading)"
        + "<div class=\"chart-scroll\">\(data)</div></div></w-chart>"
    }
    let description = [title, summary + (unit.isEmpty ? "" : " in " + unit)].filter { !$0.isEmpty }
      .joined(separator: " — ")
    return
      "<w-chart class=\"chart\"><div class=\"chart-view\" role=\"img\" aria-label=\"\(Self.escape(description)).\">"
      + heading + content + "</div><div class=\"chart-data\">\(data)</div></w-chart>"
  }

  private func table() -> String {
    let series = self.series
    // Keep surplus readable values in a fallback if a mark has more points than it has labels.
    let count = invalid || !plot ? max(labels.count, series.map(\.points.count).max() ?? 0) : labels.count
    let headers = series.enumerated().map { index, mark in
      "<th scope=\"col\">\(Self.escape(seriesName(mark, index)))</th>"
    }.joined()
    let pointRows =
      series.isEmpty
      ? ""
      : (0..<count).map { index in
        let cells = series.map { mark in
          let number = index < mark.points.count ? mark.points[index] : nil
          return "<td>\(Self.escape(number.map { withUnit($0.text) } ?? ""))</td>"
        }.joined()
        let category = index < labels.count && !labels[index].isEmpty ? labels[index] : String(index + 1)
        return "<tr><th scope=\"row\">\(Self.escape(category))</th>\(cells)</tr>"
      }.joined()
    let itemRows = marks.filter { !$0.kind.isSeries }.map { mark in
      let label = mark.label.isEmpty ? mark.kind.rawValue.capitalized : mark.label
      let value = mark.points.first.flatMap { $0 }.map { withUnit($0.text) } ?? mark.at ?? ""
      return "<tr><th scope=\"row\">\(Self.escape(label))</th><td colspan=\"\(max(1, series.count))\">"
        + "\(Self.escape(value))</td></tr>"
    }.joined()
    return "<table><thead><tr><th scope=\"col\">\(series.isEmpty ? "Label" : "Category")</th>"
      + (series.isEmpty ? "<th scope=\"col\">Value</th>" : headers) + "</tr></thead>"
      + "<tbody>\(pointRows)\(itemRows)</tbody></table>"
  }

  private func barMarks() -> String {
    let values = marks.compactMap(\.value)
    let largest = values.map(abs).max() ?? 0
    let divisor = largest == 0 ? 1 : largest
    let low = min(0, (values.min() ?? 0) / divisor)
    let high = max(0, (values.max() ?? 0) / divisor)
    let span = high > low ? high - low : 1
    let zero = -low / span
    let chosen = highlighted(values)
    let lengths = values.map { withUnit(Self.compact($0)).count }
    let width = lengths.max() ?? 0
    let rows = zip(marks, values).enumerated().map { index, entry in
      let (mark, value) = entry
      let x = (value / divisor - low) / span
      let style =
        "--chart-x:\(Self.percent(x));--chart-start:\(Self.percent(min(x, zero)));"
        + "--chart-width:\(Self.percent(abs(x - zero)))"
      let classes = "chart-bar " + Self.color(0, highlighted: chosen.map { $0 == index })
      return "<div class=\"chart-bar-row\"><span class=\"chart-bar-label\">\(Self.escape(mark.label))</span>"
        + "<div class=\"chart-bar-plot\(value < 0 ? " chart-negative" : "")\" style=\"\(style)\">"
        + "<span class=\"\(classes)\"></span><span class=\"chart-bar-value\">"
        + "\(Self.escape(withUnit(Self.compact(value))))</span></div></div>"
    }.joined()
    let negative = values.contains { $0 < 0 } ? width : 0
    return "<div class=\"chart-bars chart-scroll\" style=\"--chart-value-width:\(width);"
      + "--chart-negative-width:\(negative)\">\(rows)</div>"
  }

  private func shareMarks() -> String {
    let values = marks.compactMap(\.value)
    let maxValue = values.max() ?? 1
    let total = values.reduce(0) { $0 + $1 / maxValue }
    let segments = values.enumerated().filter { $0.element > 0 }.map { index, value in
      "<span class=\"\(Self.color(index))\" style=\"--chart-share:\(value / maxValue / total)\"></span>"
    }.joined()
    let entries = values.enumerated().map { index, value in
      (index, marks[index].label, withUnit(Self.compact(value)))
    }
    return "<div class=\"chart-shares chart-scroll\"><div class=\"chart-share\">\(segments)</div>"
      + legend(entries, shares: true) + "</div>"
  }

  private func plotMarks(ordinal: Int) -> String {
    let series = self.series
    let columns = series.indices.filter { series[$0].kind == .column }
    let rules = marks.filter { $0.kind == .rule }
    let points = series.map { Array($0.points.prefix(labels.count)) }
    let values = points.flatMap { $0.compactMap { $0?.value } }
    let scale = max(values.map(abs).max() ?? 0, rules.compactMap(\.value).map(abs).max() ?? 0)
    // Stack after scaling so even a sum near Double's upper limit stays finite.
    let divisor = scale == 0 ? 1 : scale
    let normalized = points.map { $0.map { $0.map { $0.value / divisor } } }
    let zero = !columns.isEmpty || series.contains { $0.kind == .area }
    var groupCount = 0
    var stacks: [String: Int] = [:]
    var bases: [Int: [Double]] = [:]
    var slices: [(series: Int, category: Int, group: Int, low: Double, high: Double)] = []
    var choices: [Double] = []
    for index in columns {
      let stack = series[index].stack
      let group = stack.flatMap { stacks[$0] } ?? groupCount
      if group == groupCount { groupCount += 1 }
      if let stack { stacks[stack] = group }
      var base = bases[group] ?? Array(repeating: 0, count: labels.count)
      for (category, value) in normalized[index].enumerated() {
        guard let value else { continue }
        let low = stack == nil ? 0 : base[category]
        slices.append((index, category, group, low, low + value))
        choices.append(points[index][category]!.value)
        base[category] += value
      }
      bases[group] = base
    }
    let axis = Axis(
      values: normalized.flatMap { $0.compactMap { $0 } } + slices.map(\.high)
        + rules.compactMap { $0.value.map { $0 / divisor } }, fromZero: zero, scale: divisor)
    func x(_ i: Int) -> Double {
      if labels.count == 1 { return 0.5 }
      if !columns.isEmpty { return (Double(i) + 0.5) / Double(labels.count) }
      return Double(i) / Double(labels.count - 1)
    }
    func y(_ value: Double) -> Double { 1 - axis.position(value) }
    let visibleTicks = axis.ticks.filter { ($0 * divisor).isFinite }
    let compactTicks = visibleTicks.map { Self.compact($0 * divisor) }
    let tickText =
      Set(compactTicks).count == compactTicks.count
      ? compactTicks : visibleTicks.map { String($0 * divisor) }
    let ticks = zip(visibleTicks.map(y), tickText)
    let tickWidth = ticks.map { $0.1.count }.max() ?? 1
    let grid = ticks.map { Self.ruleLine($0.0, vertical: false, classes: "chart-grid") }.joined()
    let yLabels = ticks.map { position, label in
      "<span class=\"chart-y\" style=\"--chart-y:\(Self.percent(position))\">\(label)</span>"
    }.joined()
    let labelWidth = min(11, max(5, labels.map(\.count).max() ?? 0))
    let edged = columns.isEmpty && labels.count > 1
    let xLabels = labels.enumerated().compactMap { index, label -> String? in
      let edge = edged ? (index == 0 ? " chart-first" : index == labels.count - 1 ? " chart-last" : "") : ""
      let sizes = [6, 5, 3].enumerated().compactMap { size, capacity -> String? in
        let fitting = Double(capacity * 6) / Double(labelWidth)
        let step = max(1, Int(ceil(Double(labels.count - 1) / max(1, fitting.rounded(.down) - 1))))
        // The last label ends at the plot's edge instead of centering, so the one before it needs
        // more than a label's width of room.
        let room = Double(labels.count - 1) / fitting * (edged ? 1.15 : 1)
        return index == 0 || index == labels.count - 1
          || (index % step == 0 && Double(labels.count - 1 - index) >= room)
          ? " chart-x-\(size)" : nil
      }.joined()
      guard !sizes.isEmpty else { return nil }
      return "<span class=\"chart-x\(edge)\(sizes)\" style=\"--chart-x:\(Self.percent(x(index)))\">"
        + Self.escape(label) + "</span>"
    }.joined()

    let chosen = highlighted(choices)
    let slot = 1 / Double(labels.count)
    let columnWidth = min(0.09, slot * 0.78 / Double(max(1, groupCount)))
    // Columns are HTML, not SVG: the plot's stretched viewBox would distort a rounded corner. Only the
    // far end of a column or a stack is rounded.
    let rectangles = slices.enumerated().map { index, slice in
      let origin = x(slice.category) + (Double(slice.group) - Double(groupCount) / 2) * columnWidth
      let top = min(y(slice.low), y(slice.high))
      let covered = slices.contains {
        $0.group == slice.group && $0.category == slice.category && $0.low >= slice.high && $0.high > $0.low
      }
      let cap = covered ? "" : slice.high < slice.low ? " chart-cap-down" : " chart-cap"
      return
        "<span class=\"chart-column \(Self.color(slice.series, highlighted: chosen.map { $0 == index }))\(cap)\""
        + " style=\"--chart-x:\(Self.percent(origin + columnWidth * 0.08));--chart-y:\(Self.percent(top));"
        + "--chart-width:\(Self.percent(columnWidth * 0.84));"
        + "--chart-rise:\(Self.percent(abs(y(slice.low) - y(slice.high))))\"></span>"
    }.joined()

    var fills = ""
    var strokes = ""
    var dots = ""
    for index in series.indices where series[index].kind != .column {
      var path: [(Double, Double)] = []
      let mark = series[index]
      let color = Self.color(index)
      func draw() {
        guard let first = path.first, let last = path.last else { return }
        if path.count == 1 {
          dots +=
            "<span class=\"chart-dot \(color)\" style=\"--chart-x:\(Self.percent(first.0));"
            + "--chart-y:\(Self.percent(first.1))\"></span>"
          return
        }
        let pathData = "M" + path.map { "\(Self.svg($0.0)),\(Self.svg($0.1))" }.joined(separator: " L")
        if mark.kind == .area {
          let baseline = Self.svg(1 - axis.zero)
          fills +=
            "<path class=\"chart-area \(color)\" d=\"\(pathData)"
            + " L\(Self.svg(last.0)),\(baseline) L\(Self.svg(first.0)),\(baseline) Z\"/>"
        }
        let dashed = mark.kind == .line && mark.style == "dashed" ? " chart-dashed" : ""
        strokes +=
          "<path class=\"chart-line \(color)\(dashed)\" vector-effect=\"non-scaling-stroke\" d=\"\(pathData)\"/>"
      }
      for (category, point) in normalized[index].enumerated() {
        if let point {
          path.append((x(category), y(point)))
        } else {
          draw()
          path.removeAll(keepingCapacity: true)
        }
      }
      draw()
    }

    var lines = ""
    var ruleLabels = ""
    for rule in rules {
      let vertical = rule.at != nil
      let position =
        rule.at.flatMap { labels.firstIndex(of: $0) }.map(x)
        ?? rule.value.map { y($0 / divisor) } ?? 0
      let tone = rule.tone.map { " chart-\($0)" } ?? ""
      lines += Self.ruleLine(position, vertical: vertical, classes: "chart-rule\(tone)")
      if !rule.label.isEmpty {
        let side = vertical ? (position > 0.5 ? " chart-rule-left" : " chart-rule-right") : " chart-rule-y"
        let bottom = !vertical && position < 0.17 ? " chart-rule-below" : ""
        ruleLabels +=
          "<span class=\"chart-rule-label\(side)\(bottom)\" style=\"--chart-position:\(Self.percent(position))\">"
          + Self.escape(rule.label) + "</span>"
      }
    }
    let names = series.enumerated().filter { !$0.element.label.isEmpty }.map {
      ($0.offset, $0.element.label, "")
    }
    let key = names.count >= 2 ? legend(names) : ""
    let fade =
      fills.isEmpty
      ? ""
      : """
      <defs><linearGradient id="chart-gradient-\(ordinal)" x2="0%" y2="100%">
      <stop offset="0%" class="chart-fade-start"/><stop offset="100%" class="chart-fade-end"/>
      </linearGradient><mask id="chart-mask-\(ordinal)" maskUnits="userSpaceOnUse" x="0" y="0" width="1000" height="1000">
      <rect width="1000" height="1000" fill="url(#chart-gradient-\(ordinal))"/>
      </mask></defs><g class="chart-fills" mask="url(#chart-mask-\(ordinal))">\(fills)</g>
      """
    let unit = unit.isEmpty ? "" : "<div class=\"chart-unit\">\(Self.escape(unit))</div>"
    return
      "<div class=\"chart-series\">\(unit)<div class=\"chart-axes\" style=\"--chart-tick-width:\(tickWidth);"
      + "--chart-label-width:\(labelWidth)\"><div class=\"chart-plot\"><svg viewBox=\"0 0 1000 1000\""
      + " preserveAspectRatio=\"none\" aria-hidden=\"true\">\(grid)\(fade)</svg>"
      + "\(rectangles)<svg class=\"chart-marks\" viewBox=\"0 0 1000 1000\" preserveAspectRatio=\"none\""
      + " aria-hidden=\"true\">\(strokes)\(lines)</svg>\(yLabels)\(xLabels)\(dots)\(ruleLabels)</div></div>\(key)</div>"
  }

  private func legend(_ entries: [(Int, String, String)], shares: Bool = false) -> String {
    let items = entries.map { index, name, value in
      "<li><span class=\"chart-swatch \(Self.color(index))\"></span><span class=\"chart-legend-name\">"
        + "\(Self.escape(name))</span>" + (shares ? "<span>\(Self.escape(value))</span>" : "") + "</li>"
    }.joined()
    return "<ul class=\"chart-legend\">\(items)</ul>"
  }

  private func highlighted(_ values: [Double]) -> Int? {
    let choice = highlight == "max" ? values.max() : highlight == "min" ? values.min() : nil
    return choice.flatMap { values.firstIndex(of: $0) }
  }

  private func seriesName(_ mark: Mark, _ index: Int) -> String {
    mark.label.isEmpty ? "\(mark.kind.rawValue.capitalized) \(index + 1)" : mark.label
  }

  private func withUnit(_ value: String) -> String { unit.isEmpty ? value : "\(value) \(unit)" }
  private static func escape(_ text: String) -> String { AnswerMarkdown.escape(text) }
  private static func color(_ index: Int, highlighted: Bool? = nil) -> String {
    if let highlighted { return highlighted ? "chart-color-1" : "chart-muted" }
    return "chart-color-\(index % 5 + 1)"
  }
  private static func percent(_ value: Double) -> String { "\((value * 10_000).rounded() / 100)%" }
  private static func svg(_ value: Double) -> String { String((value * 100_000).rounded() / 100) }

  private static func compact(_ value: Double) -> String {
    for (base, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "k")]
    where abs(value) >= base && abs(value) < 1e15 {
      return String(format: "%.3g", value / base) + suffix
    }
    return String(format: "%.4g", value == 0 ? 0 : value)
  }

  private static func ruleLine(_ position: Double, vertical: Bool, classes: String) -> String {
    let dimension = vertical ? "x" : "y"
    let other = vertical ? "y" : "x"
    let position = svg(position)
    return "<line class=\"\(classes)\" vector-effect=\"non-scaling-stroke\""
      + " \(dimension)1=\"\(position)\" \(dimension)2=\"\(position)\" \(other)1=\"0\" \(other)2=\"1000\"/>"
  }

  private struct Axis {
    let ticks: [Double]
    let lower: Double
    let upper: Double
    init(values: [Double], fromZero: Bool, scale: Double) {
      var low = values.min() ?? 0
      var high = values.max() ?? 0
      if fromZero {
        low = min(0, low)
        high = max(0, high)
      }
      if low == high {
        low -= low == 0 ? 0 : 0.1
        high += high == 0 ? 1 : 0.1
      }
      // Choose a nice step in data units, but place marks in normalized space to avoid overflow.
      let factor = max(pow(10, floor(log10(scale))), .leastNonzeroMagnitude)
      let ratio = scale / factor
      let step = (high - low) / 3 * ratio
      let power = max(pow(10, floor(log10(step))), .leastNonzeroMagnitude)
      let steps = [1.0, 2, 2.5, 5, 10].map { $0 * power / ratio }.filter { $0 >= (high - low) / 3 }
      let nice = steps.first { ceil(high / $0) - floor(low / $0) <= 3 } ?? steps.last ?? power / ratio
      let first = floor(low / nice)
      let last = ceil(high / nice)
      lower = first * nice
      upper = last * nice
      ticks = (0...Int(last - first)).map { (first + Double($0)) * nice }
    }

    var zero: Double { position(0) }

    func position(_ value: Double) -> Double { (value - lower) / (upper - lower) }
  }
}
