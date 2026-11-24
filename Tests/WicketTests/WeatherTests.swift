import Foundation
import Testing

@testable import WicketApp
@testable import weather

private let berlin =
  #"{"results":[{"name":"Berlin","country":"Germany","latitude":52.52,"longitude":13.41}]}"#
private let forecast = #"""
  {
    "current":{"time":"2026-11-24T23:15","temperature_2m":12.4,"apparent_temperature":9.8,
      "weather_code":2,"wind_speed_10m":13.7,"is_day":1},
    "daily":{"time":["2026-11-24","2026-11-25","2026-11-26","2026-11-27","2026-11-28"],
      "temperature_2m_max":[15,14,13,12,11],"temperature_2m_min":[8,7,6,5,4],
      "weather_code":[2,3,61,71,95]},
    "hourly":{"time":["2026-11-24T23:00","2026-11-25T00:00","2026-11-25T01:00"],
      "temperature_2m":[9,8,7],"weather_code":[0,3,61]}
  }
  """#

private func view(
  _ input: String, fields: [String: String] = [:], submitted: Bool = false,
  action: String? = nil, root: Bool = false, settings: [String: String] = [:],
  fetch: @escaping (URL) async throws -> Data
) async throws -> ProviderView {
  var request = ProviderRequest(input: input, fields: fields, action: action, submitted: submitted)
  request.rootMatch = root ? true : nil
  request.settings = settings
  let bytes = try Array(JSONEncoder().encode(request))
  var position = 0
  let output = await weatherView(weather.JSON.read(bytes, &position), fetch: fetch)
  return try JSONDecoder().decode(ProviderView.self, from: Data(output.utf8))
}

private func weatherFixture(
  city: String = "Berlin", root: Bool = false, fahrenheit: Bool = false, place: String = berlin
) -> (URL) throws -> Data {
  { url in
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    if components.host == "geocoding-api.open-meteo.com" {
      #expect(components.path == "/v1/search")
      #expect(query["name"] == city)
      if city.contains("+") { #expect(components.percentEncodedQuery?.contains("%2B") == true) }
      return Data(place.utf8)
    }

    #expect(components.host == "api.open-meteo.com" && components.path == "/v1/forecast")
    #expect(query["latitude"] == "52.52" && query["longitude"] == "13.41")
    #expect(query["temperature_unit"] == (fahrenheit ? "fahrenheit" : "celsius"))
    #expect(query["timezone"] == "auto")
    #expect(query["forecast_days"] == (root ? "1" : "5"))
    #expect(query["hourly"] == (root ? nil : "temperature_2m,weather_code"))
    #expect(query["forecast_hours"] == (root ? nil : "7"))
    let response = fahrenheit ? forecast.replacingOccurrences(of: "12.4", with: "54.3") : forecast
    return Data(response.utf8)
  }
}

@Test func weatherMatchesOnlyExplicitRootCityQueries() throws {
  let manifest = try bundled("weather").manifest
  #expect(manifest.keyword == "weather" && manifest.inputField?.name == "city")
  for input in ["weather in Berlin", "WeAtHeR  Berlin", "  weather in   New York  ", "weather Zürich"] {
    #expect(manifest.matches(input), "\(input)")
  }
  for input in ["", "weather", "weather   ", "weather in  ", "weathering in Berlin", "Berlin weather"] {
    #expect(!manifest.matches(input), "\(input)")
  }
}

@Test(arguments: [
  (0, "Clear", "sun.max"), (1, "Mostly clear", "cloud.sun"), (2, "Partly cloudy", "cloud.sun"),
  (3, "Overcast", "cloud"), (45, "Fog", "cloud.fog"), (48, "Fog", "cloud.fog"),
  (53, "Drizzle", "cloud.drizzle"), (57, "Freezing drizzle", "cloud.sleet"),
  (61, "Rain", "cloud.rain"), (65, "Heavy rain", "cloud.heavyrain"),
  (67, "Freezing rain", "cloud.sleet"), (77, "Snow", "snowflake"),
  (82, "Rain showers", "cloud.rain"), (86, "Snow showers", "cloud.snow"),
  (95, "Thunderstorm", "cloud.bolt"), (97, "Heavy thunderstorm", "cloud.bolt"),
  (99, "Thunderstorm with hail", "cloud.bolt.rain"),
  (255, "Conditions unavailable", "cloud"),
])
func weatherConditionsUseWMOCodes(_ code: Int, _ title: String, _ icon: String) {
  #expect(condition(code).title == title)
  #expect(condition(code).icon == icon)
  #expect(condition(0, night: true).icon == "moon.stars")
  #expect(condition(2, night: true).icon == "cloud.moon")
}

@Test(arguments: [false, true])
func weatherRootRowIsProminentAndOpensTheForecast(_ fahrenheit: Bool) async throws {
  let settings = fahrenheit ? ["units": "Fahrenheit"] : [:]
  let result = try await view(
    "wEaThEr   in  Berlin", fields: ["city": "wEaThEr   in  Berlin"], root: true, settings: settings,
    fetch: weatherFixture(root: true, fahrenheit: fahrenheit))
  #expect(result.body == nil && result.items.count == 1)
  let row = try #require(result.items.first)
  #expect(row.title == (fahrenheit ? "54°F · Partly cloudy" : "12°C · Partly cloudy"))
  #expect(row.icon == "cloud.sun" && row.prominent == true)
  #expect(row.subtitle == "Berlin · H: 15° L: 8° · Return for forecast")
  #expect(row.actions.map(\.label) == ["Show forecast", "Copy summary"])
  guard case .run(let address)? = row.actions.first?.kind,
    case .copy(let summary, false)? = row.actions.last?.kind
  else {
    Issue.record("Expected a forecast run action followed by a copy action")
    return
  }
  #expect(address.action == "forecast" && address.fields == ["city": "Berlin"])
  #expect(summary.contains("Berlin, Germany · \(row.title)"))

  let page = try await view(
    "", fields: address.fields ?? [:], submitted: true, action: address.action, settings: settings,
    fetch: weatherFixture(fahrenheit: fahrenheit))
  #expect(page.body?.hasPrefix("# \(row.title)\n") == true)
}

@Test func weatherForecastRendersTilesAndUpcomingLocalHours() async throws {
  let result = try await view("Berlin", fetch: weatherFixture())
  let body = try #require(result.body)
  #expect(result.items.isEmpty)
  #expect(body.contains("Berlin, Germany · Feels like 10° · H: 15° L: 8° · Wind 14 km/h"))
  #expect(body.components(separatedBy: "<tile ").count - 1 == 5)
  #expect(body.contains(#"<tile label="Tue" icon="cloud.sun" title="15° 8°"/>"#))
  #expect(body.contains(#"<row label="00:00" title="Overcast" value="8°"/>"#))
  #expect(!body.contains("23:00"))
  let html = AnswerMarkdown.html(body)
  #expect(html.contains("<w-columns") && html.contains("<w-tile") && html.contains("<w-rows"))
  #expect(result.actions.first?.label == "Copy forecast")
  guard case .copy(let text, false)? = result.actions.first?.kind else {
    Issue.record("Expected Copy forecast to copy plain text")
    return
  }
  #expect(text.contains("Sat · Thunderstorm · H: 11° L: 4°"))
  #expect(text.contains("00:00 · Overcast · 8°"))
  #expect(!text.contains("<tile"))
}

@Test func weatherUsesDefaultCityAndHonorsEditedAndKeywordFields() async throws {
  let defaultCity = try await view("", settings: ["defaultCity": " Berlin "], fetch: weatherFixture())
  #expect(defaultCity.body?.contains("Berlin, Germany") == true)
  let keyword = try await view("in  Berlin", submitted: true, fetch: weatherFixture())
  #expect(keyword.body?.contains("Berlin, Germany") == true)

  let typed = try await view(
    "ignored", fields: ["city": "In Salah + A&B"], settings: ["defaultCity": "Berlin"],
    fetch: weatherFixture(city: "In Salah + A&B"))
  #expect(typed.body != nil)
}

@Test func weatherPlaceNamesStayLiteralInForecasts() async throws {
  let place = #"""
    {"results":[{"name":"**Town**\n<row title='hi' copy='test'/>","latitude":52.52,"longitude":13.41}]}
    """#
  let result = try await view("Berlin", fetch: weatherFixture(place: place))
  let html = AnswerMarkdown.html(try #require(result.body))
  #expect(html.contains("**Town**") && html.contains("&lt;row"))
  #expect(!html.contains("<strong>Town</strong>") && !html.contains("data-copy"))
}

@Test func weatherEmptyInputsSkipBothAPIs() async throws {
  let empty = try await runBundled("weather", request: ProviderRequest(input: "   "))
  #expect(empty.body == "Type a city, or set Default city in Settings")
  for raw in ["", "weather", "weather   in "] {
    let result = try await view(raw, root: true, settings: ["defaultCity": "Berlin"]) { _ in
      Issue.record("An empty root match must not call Open-Meteo")
      throw URLError(.badURL)
    }
    #expect(result.items.isEmpty && result.body == nil)
  }
}

@Test func weatherShowsShortMessagesOnUnknownCitiesAndNetworkFailures() async throws {
  let unknown = try await view("Nowhere") { url in
    #expect(url.host == "geocoding-api.open-meteo.com", "Forecast must follow a successful geocode")
    return Data("{}".utf8)
  }
  #expect(unknown.body == "City not found")

  let unavailable = try await view("weather Berlin", root: true) { url in
    if url.host == "geocoding-api.open-meteo.com" { return Data(berlin.utf8) }
    throw URLError(.timedOut)
  }
  #expect(unavailable.body == nil)
  #expect(unavailable.items.map(\.title) == ["Weather unavailable. Try again."])
  #expect(unavailable.items.first?.actions.isEmpty == true)
}
