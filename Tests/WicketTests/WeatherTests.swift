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
  cacheDirectory: URL? = nil, fetch: @escaping (URL) async throws -> Data
) async throws -> ProviderView {
  var request = ProviderRequest(input: input, fields: fields, action: action, submitted: submitted)
  request.rootMatch = root ? true : nil
  request.settings = settings
  let bytes = try Array(JSONEncoder().encode(request))
  var position = 0
  let output = await weatherView(
    weather.JSON.read(bytes, &position), cacheDirectory: cacheDirectory, fetch: fetch)
  return try JSONDecoder().decode(ProviderView.self, from: Data(output.utf8))
}

private func weatherFixture(
  city: String = "Berlin", fahrenheit: Bool = false, place: String = berlin
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
    #expect(query["forecast_days"] == "5")
    #expect(query["hourly"] == "temperature_2m,weather_code")
    #expect(query["forecast_hours"] == "7")
    let response = fahrenheit ? forecast.replacingOccurrences(of: "12.4", with: "54.3") : forecast
    return Data(response.utf8)
  }
}

@Test func weatherRootKeywordFillsCityAndWaitsForSubmission() throws {
  let command = try bundled("weather")
  #expect(command.manifest.submit)
  let result = Ranking.compose(
    query: "weather Berlin", names: [], patterns: [:], extensions: [command.id: command.manifest],
    problems: [:], usage: UsageStore())
  let row = try #require(result.results.first)
  #expect(row.provider == command.id && row.row.title == "Weather")
  #expect(row.keywordArgument?.field == "city" && row.keywordArgument?.text == "Berlin")
  for input in ["weather Berlin", "weather in Berlin", "  WEATHER  In Salah"] {
    #expect(command.manifest.matches(input))
  }
  for input in ["weather", "weather  ", "weather in", " WEATHER   IN  ", "tomorrow weather Berlin"] {
    #expect(!command.manifest.matches(input))
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
func weatherForecastRendersTilesAndUpcomingLocalHours(_ fahrenheit: Bool) async throws {
  let settings = fahrenheit ? ["units": "Fahrenheit"] : [:]
  let result = try await view(
    "Berlin", submitted: true, settings: settings, fetch: weatherFixture(fahrenheit: fahrenheit))
  let body = try #require(result.body)
  #expect(result.items.isEmpty)
  #expect(body.hasPrefix(fahrenheit ? "# 54°F · Partly cloudy" : "# 12°C · Partly cloudy"))
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

@Test func weatherUsesDefaultCityAndHonorsSubmittedRunFields() async throws {
  let defaultCity = try await view(
    "", submitted: true, settings: ["defaultCity": " Berlin "], fetch: weatherFixture())
  #expect(defaultCity.body?.contains("Berlin, Germany") == true)

  let city = "Baden + A&B"
  let run = try await view(
    "ignored", fields: ["city": city], submitted: true, action: "forecast",
    settings: ["defaultCity": "Ignored"], fetch: weatherFixture(city: city))
  #expect(run.body?.contains("Berlin, Germany") == true)
}

@Test func weatherUsesLiteralInSalahWhenItMatches() async throws {
  let inSalah = berlin.replacingOccurrences(of: "Berlin", with: "In Salah")
    .replacingOccurrences(of: "Germany", with: "Algeria")
  let result = try await view(
    "In Salah", submitted: true, fetch: weatherFixture(city: "In Salah", place: inSalah))
  #expect(result.body?.contains("In Salah, Algeria") == true)
}

@Test func weatherRetriesInBerlinWithoutInAfterAnEmptySearch() async throws {
  var lookups: [String] = []
  let result = try await view("in Berlin", submitted: true) { url in
    if url.host == "geocoding-api.open-meteo.com" {
      let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
      let name = try #require(components.queryItems?.first { $0.name == "name" }?.value)
      lookups.append(name)
      if name == "in Berlin" { return Data("{}".utf8) }
    }
    return try weatherFixture()(url)
  }
  #expect(lookups == ["in Berlin", "Berlin"])
  #expect(result.body?.contains("Berlin, Germany") == true)
}

@Test func weatherPlaceNamesStayLiteralInForecasts() async throws {
  let place = #"""
    {"results":[{"name":"**Town**\n<row title='hi' copy='test'/>","latitude":52.52,"longitude":13.41}]}
    """#
  let result = try await view("Berlin", submitted: true, fetch: weatherFixture(place: place))
  let html = AnswerMarkdown.html(try #require(result.body))
  #expect(html.contains("**Town**") && html.contains("&lt;row"))
  #expect(!html.contains("<strong>Town</strong>") && !html.contains("data-copy"))
}

@Test func weatherRootFetchesImmediatelyAndOffersTheForecast() async throws {
  let start = ContinuousClock.now
  let result = try await view("weather Berl", root: true) { url in
    #expect(ContinuousClock.now - start < .milliseconds(400))
    return try weatherFixture(city: "Berl")(url)
  }
  #expect(result.body == nil && result.items.count == 1)
  let row = try #require(result.items.first)
  #expect(row.title == "Berlin · 12°C, partly cloudy" && row.subtitle == "H: 15° L: 8°")
  #expect(row.prominent == true && row.icon == "cloud.sun")
  #expect(row.actions == [.run(Address(fields: ["city": "Berl"]), title: "Show Forecast")])
}

@Test func weatherCachesNormalizedQueriesAndReusesForecastsForTheSamePlace() async throws {
  let cache = try scratch()
  defer { try? FileManager.default.removeItem(at: cache) }
  let first = try await view(
    "weather Berl", root: true, cacheDirectory: cache, fetch: weatherFixture(city: "Berl"))
  #expect(first.items.count == 1)

  for city in ["Berli", "Berlin"] {
    let nearby = berlin.replacingOccurrences(of: "52.52", with: "52.52001")
    let result = try await view("weather \(city)", root: true, cacheDirectory: cache) { url in
      guard url.host == "geocoding-api.open-meteo.com" else { return try unexpectedFetch(url) }
      return try weatherFixture(city: city, place: nearby)(url)
    }
    #expect(result.items.count == 1)
  }
  for city in ["BERLIN", "berli", "Berl"] {
    let cached = try await view("weather \(city)", root: true, cacheDirectory: cache, fetch: unexpectedFetch)
    #expect(cached.items.first?.title == first.items.first?.title)
  }
  let command = try await view("Berlin", submitted: true, cacheDirectory: cache, fetch: unexpectedFetch)
  #expect(command.body?.contains("Next hours") == true)
}

@Test func weatherCacheKeepsOnlyThe50MostRecentEntries() async throws {
  let directory = try scratch()
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = WeatherCache<String>(file: directory.appending(path: "test.json"))
  for index in 0...50 {
    let key = String(index)
    _ = try await cache.value(for: key) { key }
  }
  #expect(try await cache.value(for: "1") { "miss" } == "1")
  #expect(try await cache.value(for: "50") { "miss" } == "50")
  #expect(try await cache.value(for: "0") { "miss" } == "miss")
}

@Test(arguments: ["B", "Be", "Ber", "B e r", "in", "in B", "IN B e r"])
func weatherRootSkipsShortCityNames(_ city: String) async throws {
  let root = try await view(
    "weather \(city)", root: true, settings: ["defaultCity": "Berlin"], fetch: unexpectedFetch)
  #expect(root == ProviderView())
}

@Test func weatherRootIsSilentOnUnknownCitiesAndNetworkFailures() async throws {
  let cache = try scratch()
  defer { try? FileManager.default.removeItem(at: cache) }
  let unknown = try await view("weather Nowhere", root: true, cacheDirectory: cache) { url in
    #expect(url.host == "geocoding-api.open-meteo.com", "Forecast must follow a successful geocode")
    return Data("{}".utf8)
  }
  #expect(unknown == ProviderView())
  let cached = try await view("weather nowhere", root: true, cacheDirectory: cache, fetch: unexpectedFetch)
  #expect(cached == ProviderView())
  let unavailable = try await view("weather Berlin", root: true) { _ in throw URLError(.timedOut) }
  #expect(unavailable == ProviderView())
}

private func unexpectedFetch(_ url: URL) throws -> Data {
  Issue.record("Unexpected Weather API request to \(url.host ?? "unknown host")")
  throw URLError(.badURL)
}

@Test func weatherUnsubmittedCommandEditsSkipBothAPIs() async throws {
  let settings = ["defaultCity": "Berlin"]
  for prefix in ["B", "Be", "Ber", "Berlin"] {
    let typed = try await view(prefix, settings: settings, fetch: unexpectedFetch)
    #expect(typed.body == "Press Return for the forecast")
  }
  let noInput = try await view("", settings: settings, fetch: unexpectedFetch)
  #expect(noInput.body == "Press Return for the default city's forecast")
  let noDefault = try await view("   ", submitted: true, fetch: unexpectedFetch)
  #expect(noDefault.body == "Type a city, or set Default city in Settings")
}

@Test func weatherShowsShortMessagesOnUnknownCitiesAndNetworkFailures() async throws {
  let unknown = try await view("Nowhere", submitted: true) { url in
    #expect(url.host == "geocoding-api.open-meteo.com", "Forecast must follow a successful geocode")
    return Data("{}".utf8)
  }
  #expect(unknown.body == "City not found")

  let unavailable = try await view("Berlin", submitted: true) { url in
    if url.host == "geocoding-api.open-meteo.com" { return Data(berlin.utf8) }
    throw URLError(.timedOut)
  }
  #expect(unavailable.body == "Weather unavailable. Try again.")
}
