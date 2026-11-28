import Foundation

/// Ordinary page items laid out by interval within named lanes.
struct Timeline: Equatable {
  struct Input {
    let item: PageItem
    let values: [(String, String)]
  }

  struct Span: Equatable {
    let item: PageItem
    let lane: Int
    let from: Double
    let to: Double
  }

  struct Placement {
    let top: Double
    let bottom: Double
    var column = 0
    var columns = 1

    var height: Double { bottom - top }
  }

  let lanes: [String]
  let range: ClosedRange<Double>
  let clock: Bool
  let marker: Double?
  let nowLane: Int?
  let spans: [Span]

  init?(_ values: [(String, String)], spans inputs: [Input]) {
    func value(_ key: String) -> String? { values.first { $0.0 == key }?.1 }
    let lanes = (value("lanes") ?? "").split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard (1...7).contains(lanes.count), !lanes.contains(""), Set(lanes).count == lanes.count,
      inputs.count <= 100
    else { return nil }

    let sample = value("from") ?? value("to") ?? inputs.first?.values.first { $0.0 == "from" }?.1
    let clock = sample?.contains(":") == true
    func number(_ text: String?) -> Double? {
      guard let text else { return nil }
      if !clock { return Double(text).flatMap { $0.isFinite ? $0 : nil } }
      let parts = text.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
        (0...48).contains(hour), (0..<60).contains(minute), hour < 48 || minute == 0
      else { return nil }
      return Double(hour * 60 + minute)
    }
    var spans: [Span] = []
    for input in inputs {
      func part(_ key: String) -> String? { input.values.first { $0.0 == key }?.1 }
      guard input.item.title != nil, let lane = part("lane").flatMap({ lanes.firstIndex(of: $0) }),
        let from = number(part("from")), let to = number(part("to")), to > from
      else { return nil }
      spans.append(Span(item: input.item, lane: lane, from: from, to: to))
    }

    let first = spans.map(\.from).min()
    let last = spans.map(\.to).max()
    let start = first.map { clock ? ($0 / 60).rounded(.down) * 60 : $0 }
    let end = last.map { clock ? ($0 / 60).rounded(.up) * 60 : $0 }
    let lower =
      value("from") != nil
      ? number(value("from"))
      : start.map {
        clock ? min($0, max(0, (end ?? $0) - 240)) : $0
      }
    let upper =
      value("to") != nil
      ? number(value("to"))
      : end.map {
        clock ? min(max(1440, $0), max($0, (lower ?? $0) + 240)) : $0
      }
    guard let lower, let upper, upper > lower, (upper - lower).isFinite,
      (upper - lower) / 5 > 0, spans.allSatisfy({ $0.to > lower && $0.from < upper })
    else { return nil }

    self.lanes = lanes
    range = lower...upper
    self.clock = clock
    nowLane = value("now-lane").flatMap { lanes.firstIndex(of: $0) }
    if let now = number(value("now")), range.contains(now), value("now-lane") == nil || nowLane != nil {
      marker = now
    } else {
      marker = nil
    }
    self.spans = spans.map {
      Span(item: $0.item, lane: $0.lane, from: max(lower, $0.from), to: min(upper, $0.to))
    }
  }

  var ticks: [Double] {
    let width = range.upperBound - range.lowerBound
    if clock {
      let step: Double = width > 12 * 60 ? 120 : 60
      return Array(
        stride(from: (range.lowerBound / step).rounded(.up) * step, through: range.upperBound, by: step))
    }
    return (0...5).map { range.lowerBound + width * (Double($0) / 5) }
  }

  func fraction(_ value: Double) -> Double {
    (value - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  func label(_ value: Double) -> String {
    if !clock {
      return abs(value) >= 1_000_000 || (value != 0 && abs(value) < 0.001)
        ? value.formatted(.number.notation(.scientific).precision(.significantDigits(1...4)))
        : value.formatted(.number.precision(.significantDigits(1...6)))
    }
    let minutes = Int(value)
    return String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  func placements(height: Double, minimum: Double) -> [Placement] {
    let minimum = min(height, minimum)
    var placements = spans.map { span in
      let start = fraction(span.from) * height
      let end = fraction(span.to) * height - 1
      if end - start >= minimum { return Placement(top: start, bottom: end) }
      // Use the gap above a short card before adding a column for an event that starts after it ends.
      let next = spans.lazy.filter { $0.lane == span.lane && $0.from >= span.to }.map(\.from).min()
      let limit = next.map { fraction($0) * height } ?? height
      let top = max(0, min(start, limit - minimum))
      return Placement(top: top, bottom: top + minimum)
    }
    // Minimum-height cards can collide even if their original intervals did not.
    for lane in lanes.indices {
      let ordered = spans.indices.filter { spans[$0].lane == lane }.sorted {
        (placements[$0].top, spans[$0].from, $0) < (placements[$1].top, spans[$1].from, $1)
      }
      var group: [Int] = []
      var ends: [Double] = []
      func finish() {
        for index in group { placements[index].columns = ends.count }
        group.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
      }
      for index in ordered {
        let from = placements[index].top
        if ends.allSatisfy({ $0 <= from }) { finish() }
        let column = ends.firstIndex { $0 <= from } ?? ends.count
        if column == ends.count {
          ends.append(placements[index].bottom)
        } else {
          ends[column] = placements[index].bottom
        }
        placements[index].column = column
        group.append(index)
      }
      finish()
    }
    return placements
  }
}
