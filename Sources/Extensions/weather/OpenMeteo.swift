import Foundation

struct Place: Decodable {
  let name: String
  let country: String?
  let latitude: Double
  let longitude: Double

  var location: String { [name, country].compactMap { $0 }.joined(separator: ", ") }
}

struct Forecast: Decodable {
  struct Current: Decodable {
    let time: String
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

  struct Daily: Decodable {
    let time: [String]
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

  struct Hourly: Decodable {
    let time: [String]
    let temperatures: [Double?]
    let weatherCode: [Int?]

    private enum CodingKeys: String, CodingKey {
      case time
      case temperatures = "temperature_2m"
      case weatherCode = "weather_code"
    }
  }

  let current: Current
  let daily: Daily
  let hourly: Hourly?
}

struct OpenMeteo {
  let fetch: (URL) async throws -> Data

  func place(named city: String) async throws -> Place? {
    if let place = try await geocode(city) { return place }
    let parts = city.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard parts.count == 2, parts[0].lowercased() == "in" else { return nil }
    return try await geocode(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func geocode(_ city: String) async throws -> Place? {
    struct Search: Decodable {
      let results: [Place]?
    }

    let search: Search = try await get(
      "https://geocoding-api.open-meteo.com/v1/search", [("name", city), ("count", "1")])
    return search.results?.first
  }

  func forecast(for place: Place, fahrenheit: Bool) async throws -> Forecast {
    let query = [
      ("latitude", String(place.latitude)),
      ("longitude", String(place.longitude)),
      ("timezone", "auto"),
      ("temperature_unit", fahrenheit ? "fahrenheit" : "celsius"),
      ("current", "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
      ("daily", "weather_code,temperature_2m_max,temperature_2m_min"),
      ("forecast_days", "5"),
      ("hourly", "temperature_2m,weather_code"),
      ("forecast_hours", "7"),
    ]
    return try await get("https://api.open-meteo.com/v1/forecast", query)
  }

  private func get<T: Decodable>(_ endpoint: String, _ query: [(String, String)]) async throws -> T {
    var url = URLComponents(string: endpoint)!
    url.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    try Task.checkCancellation()
    return try JSONDecoder().decode(T.self, from: await fetch(url.url!))
  }
}
