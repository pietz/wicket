import Foundation
import Testing
import WebKit

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
  private func html(_ body: String, streaming: Bool = false) -> String {
    let page = Page(body: body, runs: true, streaming: streaming)
    return AnswerMarkdown.html(page.source, code: page.code, streaming: streaming, fields: page.fields)
  }

  @Test func bars() throws {
    let result = html(try #require(ChartFixture.all["chart-bars"]).body)
    #expect(result.contains("chart-bar chart-color-1"))
    #expect(result.contains("chart-bar chart-muted"))
    #expect(result.contains("4.8 s"))
    #expect(result.contains("role=\"img\" aria-label=\"Build time by target"))
    #expect(result.contains("class=\"chart-data\"><table>"))
    #expect(!result.contains("<svg"))
  }

  @Test func areaAndRules() throws {
    let result = html(try #require(ChartFixture.all["chart-area"]).body)
    #expect(result.contains("<svg viewBox=\"0 0 1000 1000\" preserveAspectRatio=\"none\""))
    #expect(result.contains("<path class=\"chart-area chart-color-1\""))
    #expect(result.contains("<line class=\"chart-rule chart-warning\" vector-effect=\"non-scaling-stroke\""))
    #expect(result.contains("x1=\"800.0\" x2=\"800.0\""))
    #expect(result.contains("Deploy</span>"))
    #expect(result.contains("200 ms</td>"))
    #expect(!result.contains("<w-line"))
    #expect(!result.contains("<p>"))
  }

  @Test func stackedColumnsAndLine() throws {
    let result = html(try #require(ChartFixture.all["chart-columns"]).body)
    let columns = result.matches(
      of:
        /<span class="chart-column chart-color-([12])( chart-cap)?" style="--chart-x:([^;]+);--chart-y:([^;]+);/
    )
    try #require(columns.count == 8)
    #expect(columns[0].3 == columns[4].3)
    #expect(columns[0].4 != columns[4].4)
    // Only the top of each stack is rounded.
    #expect(columns.map { $0.2 != nil } == [false, false, false, false, true, true, true, true])
    #expect(result.contains("chart-line chart-color-3 chart-dashed"))
    #expect(result.contains("<ul class=\"chart-legend\">"))
    #expect(result.contains("Enterprise</span>"))
  }

  @Test func shares() throws {
    let result = html(try #require(ChartFixture.all["chart-shares"]).body)
    #expect(result.contains("class=\"chart-share\""))
    #expect(result.ranges(of: "--chart-share:").count == 3)
    #expect(result.contains("194 GB</span>"))
    #expect(!result.contains("<svg"))
  }

  @Test(arguments: [
    #"<bar label="Good & <safe>" value="3"/><share label="Share" value="2"/>"#,
    #"<bar label="Good & <safe>" value="3"/><bar label="Bad" value="NaN"/>"#,
    #"<bar label="Good & <safe>" value="3"/><bar label="Bad" value="Infinity"/>"#,
    #"<bar label="Good & <safe>" value="3"/><row title="Hidden" run="effect"/>"#,
    #"<share label="Good & <safe>" value="3"/><share label="Bad" value="-2"/>"#,
    #"<bar label="Good & <safe>" value="3">Unexpected</bar>"#,
  ])
  func invalidChartFallsBack(_ marks: String) {
    let result = html("<chart>\(marks)</chart>")
    #expect(result.contains("class=\"chart-fallback\""))
    #expect(result.contains("<table>"))
    #expect(!result.contains("<svg"))
    #expect(!result.contains("<safe>"))
    #expect(!result.contains("data-target"))
    #expect(result.contains("Good &amp; &lt;safe&gt;"))
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
  func invalidSeriesOrEmptyChartFallsBack(_ body: String) {
    #expect(html(body).contains("class=\"chart-fallback\""))
  }

  @Test func gapsAndLengths() {
    let body = """
      <chart labels="A,B,C,D,E">
      <line name="Short" values="1,,3,4"/>
      <line name="Long" values="1,2,3,4,5,999"/>
      </chart>
      """
    let result = html(body)
    #expect(result.contains("class=\"chart-dot chart-color-1\""))
    #expect(result.contains("<td></td><td>2</td>"))
    #expect(result.contains("<td></td><td>5</td>"))
    #expect(!result.contains("999"))
  }

  @Test func streamsAsOneBlock() throws {
    let body = try #require(ChartFixture.all["chart-area"]).body
    let partial = String(body.dropLast("</chart>".count))
    let pending = html(partial, streaming: true)
    #expect(pending.contains("class=\"chart-pending\""))
    #expect(pending.contains("API p95 latency"))
    #expect(!pending.contains("<svg"))
    #expect(!pending.contains("<table"))
    #expect(pending == html(String(partial.prefix(while: { $0 != "\n" })), streaming: true))
    let final = html(body, streaming: true)
    #expect(final.contains("<svg"))
    #expect(!final.contains("chart-pending"))
    #expect(final == html(body))
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
      let result = AnswerMarkdown.html(page.source, code: page.code)
      #expect(result.contains("class=\"chart\""))
      #expect(!result.contains("data-target=\"hack\""))
      #expect(!result.contains("secret"))
      #expect(!result.contains("Hidden"))
      #expect(result.ranges(of: "<button aria-label=\"Copy code\">").count == 1)
    }
  }

  @Test func longChartTagsAndOrdinaryLimit() {
    let labels = (1...100).map { "Category \($0)" }.joined(separator: ",")
    let points = (1...100).map { "\($0).123456789" }.joined(separator: ",")
    let result = html("<chart labels=\"\(labels)\"><line values=\"\(points)\"/></chart>")
    #expect(result.contains("<svg"))
    #expect(result.contains("Category 100</th>"))
    #expect(result.contains("100.123456789</td>"))
    let tooLong = String(repeating: "x", count: 4100)
    let row = #"<row title="Keep" copy=""# + tooLong + #""/>"#
    #expect(Page(body: row, runs: false).targets.isEmpty)
    #expect(!html(row).contains("<w-row"))
    let shorter = String(repeating: "x", count: 600)
    let ordinary = Page(body: "<row title=\"\(shorter)\"/>", runs: true)
    #expect(ordinary.source.contains(String(shorter.prefix(300)) + "\"/>"))
    let tooMany = Array(repeating: "A", count: 201).joined(separator: ",")
    #expect(html("<chart labels=\"\(tooMany)\"><line values=\"1\"/></chart>").contains("chart-fallback"))
    let oversized = Array(repeating: "1.12345678901234567890", count: 200).joined(separator: ",")
    #expect(html("<chart labels=\"A\"><line values=\"\(oversized)\"/></chart>").contains("chart-fallback"))
    let oversizedTitle = String(repeating: "x", count: 4_096)
    let oversizedChart = html(
      "<chart title=\"\(oversizedTitle)\"><bar label=\"Readable\" value=\"1\"/></chart>")
    #expect(oversizedChart.contains("chart-fallback"))
    #expect(oversizedChart.contains("Readable</th>"))
    #expect(!oversizedChart.contains(oversizedTitle))
  }

  @Test func reviewedEdges() {
    // A range narrower than a Double can resolve still gets distinct axis bounds.
    let close = html(#"<chart labels="A,B"><line values="0.9999999999999999,1"/></chart>"#)
    #expect(close.contains("chart-line") && !close.contains("nan") && !close.contains("inf"))
    // Several column series keep the colors their legend names.
    let several = html(
      #"<chart labels="Q1,Q2" highlight="max"><column name="Sales" values="1,2"/>"#
        + #"<column name="Costs" values="3,4"/></chart>"#)
    #expect(several.contains("chart-column chart-color-2") && !several.contains("chart-muted"))
    let lone = html(#"<chart labels="Q1,Q2" highlight="max"><column values="1,2"/></chart>"#)
    #expect(lone.contains("chart-muted"))
    // A value beyond the labels is not plotted and does not spoil the chart.
    let surplus = html(#"<chart labels="Mon,Tue"><line values="4,7,N/A"/></chart>"#)
    #expect(surplus.contains("chart-line") && !surplus.contains("chart-fallback"))
  }

  @Test func malformedChartKeepsJSONItemsReachable() {
    let body = #"<chart><bar label="Readable" value="1"/><chart>"#
    let item = Row(id: "after", title: "After", actions: [.copy("after")])
    let page = Page(body: body, items: [item], runs: true)
    let result = AnswerMarkdown.html(page.source)
    #expect(page.targets.map(\.id) == ["after"])
    #expect(result.contains("Readable</th>"))
    #expect(result.contains("</w-chart><w-rows>"))
    #expect(result.contains("data-target=\"after\""))
  }

  @MainActor @Test(.timeLimit(.minutes(1))) func chartLayoutAndStreamingInWebKit() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let renderer = AnswerRenderer(folder: folder) { _ in }
    defer { renderer.release() }
    let body = try #require(ChartFixture.all["chart-area"]).body
    let partial = String(body.dropLast("</chart>".count))
    renderer.update(Page(body: partial, runs: false, streaming: true), turn: "chart", streaming: true)
    await renderer.settled()
    let web = try #require(renderer.page)
    let pending =
      try await web.callJavaScript(
        "return document.querySelector('w-chart.chart-pending').getBoundingClientRect().height;",
        contentWorld: .defaultClient) as? Double
    #expect((pending ?? 0) > 0)

    renderer.update(Page(body: body, runs: false, streaming: true), turn: "chart", streaming: true)
    await renderer.settled()
    let final =
      try await web.callJavaScript(
        """
        const chart = document.querySelector('w-chart.chart');
        globalThis.finishedChart = chart.querySelector('.chart-area');
        const line = chart.querySelector('.chart-line');
        return [chart.getBoundingClientRect().height, line.getBBox().width,
          Number.parseFloat(getComputedStyle(line).strokeWidth)];
        """, contentWorld: .defaultClient) as? [Double]
    #expect(final?.first == pending)
    #expect(final?.dropFirst().first == 1000)
    #expect(final?.last == 2)

    renderer.update(Page(body: body + "\n\nDone.", runs: false), turn: "chart", streaming: false)
    await renderer.settled()
    let stable =
      try await web.callJavaScript(
        "return globalThis.finishedChart === document.querySelector('.chart-area');",
        contentWorld: .defaultClient) as? Bool
    #expect(stable == true)

    let result =
      try await web.callJavaScript(
        """
        const chart = document.querySelector('w-chart');
        return [560, 339, 268].map(width => {
          chart.style.width = width + 'px';
          const labels = [...chart.querySelectorAll('.chart-x')].filter(label => label.offsetWidth);
          const bounds = labels.map(label => label.getBoundingClientRect());
          const clear = bounds.every((rect, i) => !i || rect.left >= bounds[i - 1].right);
          const ticks = [...chart.querySelectorAll('.chart-y')];
          return [labels.length, labels[0].textContent, labels.at(-1).textContent,
            clear, ticks.every(tick => tick.getBoundingClientRect().height < 20)];
        });
        """, contentWorld: .defaultClient) as? [[Any]]
    let layouts = try #require(result)
    #expect(layouts.compactMap { $0[0] as? Int } == [6, 6, 3])
    for layout in layouts {
      #expect(layout[1] as? String == "10:00")
      #expect(layout[2] as? String == "15:00")
      #expect(layout[3] as? Bool == true)
      #expect(layout[4] as? Bool == true)
    }
  }

  @Test func chartsInsideLayoutContainersAndCode() {
    let chart = #"<chart><bar label="A" value="2"/></chart>"#
    let result = html("<columns>\n<card>\n## Example\n\(chart)\n</card>\n\(chart)\n</columns>")
    #expect(
      result.matches(
        of: /(?s)<w-columns.*<w-card.*<w-chart .*<\/w-chart><\/w-card><w-chart .*<\/w-chart><\/w-columns>/
      ).count == 1)
    let code = html("Example: `\(chart)`\n\n```html\n\(chart)\n```")
    #expect(!code.contains("<w-chart"))
    #expect(code.ranges(of: "&lt;chart&gt;").count == 2)
  }
}

/// Hardware-matched accents have their own `AppleAccentColor` indices; their hue still picks the skip.
@Test(arguments: [
  (211.0, 1.0, "4"), (348.0, 0.5, "0"), (30.0, 0.9, "1"), (130.0, 0.8, "3"), (280.0, 0.7, "5"),
  (330.0, 0.8, "6"), (5.0, 0.9, "0"), (60.0, 0.9, "2"), (200.0, 0.05, ""),
])
func accentHueFamiliesMatchTheSkippedSystemColour(hue: Double, saturation: Double, family: String) {
  #expect(AnswerRenderer.accentFamily(hue: hue, saturation: saturation) == family)
}
