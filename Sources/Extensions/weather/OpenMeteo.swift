import Foundation

struct Place: Codable {
  let name: String
  let country: String?
  let latitude: Double
  let longitude: Double

  var location: String { [name, country].compactMap { $0 }.joined(separator: ", ") }
}

func cityWithoutIn(_ city: String) -> String? {
  let parts = city.split(maxSplits: 1, whereSeparator: \.isWhitespace)
  guard parts.count == 2, parts[0].lowercased() == "in" else { return nil }
  return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
}

struct Forecast: Codable {
  struct Current: Codable {
    let time: TimeInterval
    let temperature: Double
    let apparentTemperature: Double
    let weatherCode: Int
    let windSpeed: Double
    let isDay: Int

    private enum CodingKeys: String, CodingKey {
      case time
      case temperature = "temperature_2m"
      case apparentTemperature = "apparent_temperature"
      case weatherCode = "weather_code"
      case windSpeed = "wind_speed_10m"
      case isDay = "is_day"
    }
  }

  struct Daily: Codable {
    let time: [TimeInterval]
    let highs: [Double?]
    let lows: [Double?]
    let weatherCode: [Int?]

    private enum CodingKeys: String, CodingKey {
      case time
      case highs = "temperature_2m_max"
      case lows = "temperature_2m_min"
      case weatherCode = "weather_code"
    }
  }

  struct Hourly: Codable {
    let time: [TimeInterval]
    let temperatures: [Double?]
    let weatherCode: [Int?]
    let precipitationProbability: [Int?]
    let isDay: [Int?]

    private enum CodingKeys: String, CodingKey {
      case time
      case temperatures = "temperature_2m"
      case weatherCode = "weather_code"
      case precipitationProbability = "precipitation_probability"
      case isDay = "is_day"
    }
  }

  let current: Current
  let daily: Daily
  let hourly: Hourly?
  let timezone: String
  let utcOffsetSeconds: Int

  private enum CodingKeys: String, CodingKey {
    case current, daily, hourly, timezone
    case utcOffsetSeconds = "utc_offset_seconds"
  }
}

struct OpenMeteo {
  let cacheDirectory: URL?
  let fetch: (URL) async throws -> Data

  func place(named city: String) async throws -> Place? {
    if let place = try await geocode(city) { return place }
    guard let fallback = cityWithoutIn(city) else { return nil }
    return try await geocode(fallback)
  }

  private func geocode(_ city: String) async throws -> Place? {
    struct Search: Decodable {
      let results: [Place]?
    }

    let key = city.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .precomposedStringWithCanonicalMapping.lowercased()
    let cache = WeatherCache<Place?>(file: cacheDirectory?.appending(path: "geocoding.json"))
    return try await cache.value(for: key) {
      let search: Search = try await get(
        "https://geocoding-api.open-meteo.com/v1/search", [("name", city), ("count", "1")])
      return search.results?.first
    }
  }

  func forecast(for place: Place, fahrenheit: Bool) async throws -> Forecast {
    let unit = fahrenheit ? "fahrenheit" : "celsius"
    let coordinates = [place.latitude, place.longitude].map { coordinate in
      let rounded = (coordinate * 10_000).rounded()
      return rounded == 0 ? "0" : String(rounded)
    }.joined(separator: ",")
    let cache = WeatherCache<Forecast>(file: cacheDirectory?.appending(path: "forecasts.json"))
    return try await cache.value(for: "\(coordinates),\(unit)") {
      try await get(
        "https://api.open-meteo.com/v1/forecast",
        [
          ("latitude", String(place.latitude)),
          ("longitude", String(place.longitude)),
          ("timezone", "auto"),
          ("timeformat", "unixtime"),
          ("temperature_unit", unit),
          ("current", "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
          ("daily", "weather_code,temperature_2m_max,temperature_2m_min"),
          ("forecast_days", "5"),
          ("hourly", "temperature_2m,weather_code,precipitation_probability,is_day"),
          ("forecast_hours", "13"),
        ])
    }
  }

  private func get<T: Decodable>(_ endpoint: String, _ query: [(String, String)]) async throws -> T {
    var url = URLComponents(string: endpoint)!
    url.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    try Task.checkCancellation()
    return try JSONDecoder().decode(T.self, from: await fetch(url.url!))
  }
}
