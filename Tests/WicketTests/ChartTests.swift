import Foundation
import Testing

@testable import WicketApp

struct ChartFixture: Decodable {
  let question: String
  let body: String
  let text: [String]

  static let all: [String: Self] = {
    let file = Bundle.module.url(
      forResource: "capture-charts", withExtension: "json", subdirectory: "Fixtures")!
    return try! JSONDecoder().decode([String: Self].self, from: Data(contentsOf: file))
  }()
}

struct ChartTests {
  private func chart(_ body: String, streaming: Bool = false) -> (Chart, Bool)? {
    document(body, streaming: streaming).blocks.compactMap {
      if case .chart(let chart, let pending) = $0 { (chart, pending) } else { nil }
    }.first
  }

  @Test(arguments: ["chart-bars", "chart-area", "chart-columns", "chart-shares"])
  func validChartFixturesRender(_ name: String) throws {
    let body = try #require(ChartFixture.all[name]).body
    let (parsed, pending) = try #require(chart(body))
    #expect(!parsed.invalid && !pending)
    switch name {
    case "chart-bars":
      #expect(parsed.bars && parsed.withUnit("4.8") == "4.8 s")
      #expect(parsed.highlighted(parsed.marks.compactMap(\.value)) != nil)
    case "chart-area":
      #expect(parsed.plot && parsed.series.first?.kind == .area)
      #expect(parsed.marks.last?.label == "Deploy" && parsed.marks.last?.at == "14:00")
      #expect(parsed.marks.contains { $0.kind == .rule && $0.label == "SLA" && $0.tone == "warning" })
    case "chart-columns":
      #expect(parsed.plot && parsed.series.map(\.kind) == [.column, .column, .line])
      #expect(parsed.series[0].stack == parsed.series[1].stack && parsed.series[2].style == "dashed")
    default:
      #expect(parsed.shares && parsed.marks.count == 3)
      #expect(
        parsed.marks.contains { parsed.withUnit($0.points.first.flatMap { $0 }?.text ?? "") == "194 GB" })
    }
  }

  @Test(arguments: [
    #"<bar label="Good & <safe>" value="3"/><share label="Share" value="2"/>"#,
    #"<bar label="Good & <safe>" value="3"/><bar label="Bad" value="NaN"/>"#,
    #"<bar label="Good & <safe>" value="3"/><bar label="Bad" value="Infinity"/>"#,
    #"<bar label="Good & <safe>" value="3"/><row title="Hidden" run="effect"/>"#,
    #"<share label="Good & <safe>" value="3"/><share label="Bad" value="-2"/>"#,
    #"<bar label="Good & <safe>" value="3">Unexpected</bar>"#,
  ])

  func invalidChartPreservesReadableData(_ marks: String) throws {
    let (parsed, _) = try #require(chart("<chart>\(marks)</chart>"))
    #expect(parsed.invalid || !parsed.plot && !parsed.bars && !parsed.shares)
    #expect(parsed.marks.first?.label == "Good & <safe>")
    #expect(parsed.marks.first?.value == 3)
  }

  @Test(arguments: [
    #"<chart title="Empty"></chart>"#,
    #"<chart><line values="1,2"/></chart>"#,
    #"<chart labels="Mon,Tue"><area values="1,2"/><rule at="Wed"/></chart>"#,
    #"<chart labels="Mon,Tue"><column stack="a" values="1,-2"/></chart>"#,
    #"<chart labels="Mon,Tue"><line values="bad,2"/></chart>"#,
    #"<chart labels="A"><line values=""/><rule value="2"/></chart>"#,
    #"<chart><share label="None" value="0"/></chart>"#,
  ])

  func invalidSeriesOrEmptyChartFallsBack(_ body: String) throws {
    let (parsed, _) = try #require(chart(body))
    #expect(
      parsed.invalid || !parsed.plot && !parsed.bars && parsed.marks.allSatisfy { ($0.value ?? 0) <= 0 })
  }

  @Test func gapsAndRepeatedCategoriesAreKeptByPosition() throws {
    let (parsed, _) = try #require(
      chart(
        """
        <chart labels="A,B,A,D,E">
        <line name="Short" values="1,,3,4"/>
        <line name="Long" values="1,2,3,4,5,999"/>
        </chart>
        """))
    #expect(!parsed.invalid && parsed.labels == ["A", "B", "A", "D", "E"])
    #expect(parsed.series[0].points.map { $0?.value } == [1, nil, 3, 4])
    #expect(parsed.series[1].points.compactMap { $0?.value } == [1, 2, 3, 4, 5])
  }

  @MainActor @Test func aStreamedPlotKeepsItsPlaceholderHeight() throws {
    let body = try #require(ChartFixture.all["chart-area"]).body
    let partial = String(body.dropLast("</chart>".count))
    let renderer = NativePageRenderer()
    renderer.update(Page(body: partial, runs: false, streaming: true), turn: "chart", streaming: true)
    let height = renderer.height
    #expect(height > PaletteLayout.answerMin)
    #expect(chart(partial, streaming: true)?.1 == true && chart(body, streaming: true)?.1 == false)
    renderer.update(Page(body: body, runs: false), turn: "chart")
    #expect(renderer.height == height)
  }

  @Test func chartsNeverContributeTargets() {
    let body = """
      <row title="Before" copy="before"/>
      <chart title="Plain" open="https://example.com" copy="secret" ask="ask" run="first" target="hack">
      <bar label="One" value="1" open="https://example.com" copy="secret" ask="do" run="second" target="hack"/>
      </chart>
      <chart title="Invalid">
      <row title="Hidden" run="third"/>
      ```sh
      printf hi
      ```
      </chart>
      <row title="After" run="fourth"/>
      ```
      code
      ```
      """
    for runs in [true, false] {
      let page = Page(body: body, runs: runs)
      #expect(page.targets.map(\.title) == (runs ? ["Before", "After", "Code"] : ["Before", "Code"]))
      #expect(page.targets.map(\.id) == (runs ? ["#0", "#1", "#2"] : ["#0", "#1"]))

      let blocks = PageDocument(page, turn: "t", streaming: false).blocks
      #expect(blocks.filter { if case .chart = $0 { true } else { false } }.count == 2)
      #expect(!blocks.map(\.renderedText).joined().contains("Hidden"))
      #expect(blocks.last == .code("code", target: runs ? "#2" : "#1"))
    }
  }

  @Test func longChartTagsAndOrdinaryLimit() throws {
    let labels = (1...100).map { "Category \($0)" }.joined(separator: ",")
    let points = (1...100).map { "\($0).123456789" }.joined(separator: ",")
    let (parsed, _) = try #require(chart("<chart labels=\"\(labels)\"><line values=\"\(points)\"/></chart>"))
    #expect(!parsed.invalid && parsed.labels.last == "Category 100")
    #expect(parsed.series.first?.points.last.flatMap { $0 }?.text == "100.123456789")
    let row = #"<row title="Keep" copy=""# + String(repeating: "x", count: 4100) + #""/>"#
    #expect(Page(body: row, runs: false).targets.isEmpty)
    let tooMany = Array(repeating: "A", count: 201).joined(separator: ",")
    #expect(chart("<chart labels=\"\(tooMany)\"><line values=\"1\"/></chart>")?.0.invalid == true)
    let oversized = Array(repeating: "1.12345678901234567890", count: 200).joined(separator: ",")
    #expect(chart("<chart labels=\"A\"><line values=\"\(oversized)\"/></chart>")?.0.invalid == true)
    let oversizedTitle = String(repeating: "x", count: 4_096)
    let (fallback, _) = try #require(
      chart(
        "<chart title=\"\(oversizedTitle)\"><bar label=\"Readable\" value=\"1\"/></chart>"))
    #expect(fallback.invalid && fallback.title.isEmpty && fallback.marks.first?.label == "Readable")
  }

  @Test func malformedChartKeepsJSONItemsReachable() throws {
    let body = #"<chart><bar label="Readable" value="1"/><chart>"#
    let item = Row(id: "after", title: "After", actions: [.copy("after")])
    let page = Page(body: body, items: [item], runs: true)
    let blocks = PageDocument(page, turn: "t", streaming: false).blocks
    #expect(page.targets.map(\.id) == ["after"])
    #expect(blocks.count == 2 && blocks.last?.holds("after") == true)
  }

  @Test func chartsInsideLayoutContainersAndCode() {
    let chart = #"<chart><bar label="A" value="2"/></chart>"#
    let boxes = document("<columns>\n<card>\n## Example\n\(chart)\n</card>\n\(chart)\n</columns>").blocks
    #expect(boxes.first?.children.last == boxes.first?.children.first?.children.last)
    let code = document("Example: `\(chart)`\n\n```html\n\(chart)\n```").blocks
    #expect(code.map(\.renderedText) == ["Example: " + chart, chart])
  }
}

/// Hardware-matched accents have their own `AppleAccentColor` indices; their hue still picks the skip.
@Test(arguments: [
  (211.0, 1.0, "4"), (348.0, 0.5, "0"), (30.0, 0.9, "1"), (130.0, 0.8, "3"), (280.0, 0.7, "5"),
  (330.0, 0.8, "6"), (5.0, 0.9, "0"), (60.0, 0.9, "2"), (200.0, 0.05, ""),
])
func accentHueFamiliesMatchTheSkippedSystemColour(hue: Double, saturation: Double, family: String) {
  #expect(Ink.accentFamily(hue: hue, saturation: saturation) == family)
}
