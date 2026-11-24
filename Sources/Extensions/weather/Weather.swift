import Foundation

func weatherView(_ request: JSON?, fetch: @escaping (URL) async throws -> Data) async -> String {
  let settings = request?["settings"]
  let input = request?["fields"]?["city"]?.string ?? request?["input"]?.string ?? ""
  let rootMatch = request?["rootMatch"]?.isTrue == true

  var city = input.trimmingCharacters(in: .whitespacesAndNewlines)
  if rootMatch {
    let parts = city.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard parts.count == 2, parts[0].lowercased() == "weather" else {
      return #"{"items":[]}"#
    }
    city = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    if city.lowercased() == "in" { return #"{"items":[]}"# }
  }

  // The root keyword shortcut submits everything after “weather” as the city field.
  if rootMatch || (request?["submitted"]?.isTrue == true && request?["action"]?.string == nil) {
    let parts = city.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    if parts.count == 2, parts[0].lowercased() == "in" {
      city = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
  if city.isEmpty {
    city = settings?["defaultCity"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
  guard !city.isEmpty else { return message("Type a city, or set Default city in Settings") }

  let fahrenheit = settings?["units"]?.string == "Fahrenheit"
  let api = OpenMeteo(fetch: fetch)
  do {
    guard let place = try await api.place(named: city) else {
      return message("City not found", root: rootMatch)
    }
    let forecast = try await api.forecast(for: place, fahrenheit: fahrenheit, summary: rootMatch)
    let current = forecast.current
    let weather = condition(current.weatherCode, night: current.isDay == 0)
    let title = "\(degrees(current.temperature))\(fahrenheit ? "F" : "C") · \(weather.title)"
    let high = degrees(forecast.daily.highs.first ?? nil)
    let low = degrees(forecast.daily.lows.first ?? nil)
    let range = "H: \(high) L: \(low)"
    if rootMatch {
      let subtitle = "\(place.name) · \(range) · Return for forecast"
      let summary = "\(place.location) · \(title) · \(range)\nWeather data by Open-Meteo"
      return #"""
        {"items":[{"id":"weather","title":\#(quoted(title)),"subtitle":\#(quoted(subtitle)),
        "icon":\#(quoted(weather.icon)),"prominent":true,"actions":[
        {"type":"run","title":"Show forecast","action":"forecast","fields":{"city":\#(quoted(city))}},
        {"type":"copy","title":"Copy summary","text":\#(quoted(summary))}]}]}
        """#
    }
    let details =
      "Feels like \(degrees(current.apparentTemperature)) · \(range) · Wind \(whole(current.windSpeed)) km/h"
    return forecastPage(title: title, location: place.location, details: details, forecast: forecast)
  } catch {
    return message("Weather unavailable. Try again.", root: rootMatch)
  }
}

private func message(_ title: String, root: Bool = false) -> String {
  root
    ? #"{"items":[{"id":"unavailable","title":\#(quoted(title)),"actions":[]}]}"#
    : #"{"body":\#(quoted(title))}"#
}

private func forecastPage(title: String, location: String, details: String, forecast: Forecast) -> String {
  // Escape Markdown punctuation and squeeze line breaks so place names stay plain text.
  let place = location.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  let syntax = CharacterSet(charactersIn: "!\"#&'()*+-.<>[\\]_`{|}~:")
  let literal = place.unicodeScalars.map {
    syntax.contains($0) ? "&#\($0.value);" : String($0)
  }.joined()
  var body = ["# \(title)", "\(literal) · \(details)"]
  var copy = [title, "\(place) · \(details)"]

  let daily = forecast.daily
  let isoDate = ISO8601DateFormatter()
  isoDate.formatOptions = [.withFullDate]
  let weekday = DateFormatter()
  weekday.locale = Locale(identifier: "en_US_POSIX")
  weekday.timeZone = .gmt
  weekday.dateFormat = "EEE"
  let days = zip(daily.time, zip(daily.highs, daily.lows))
  var tiles: [String] = []
  var dailyLines: [String] = []
  for ((date, (high, low)), code) in zip(days, daily.weatherCode) {
    guard let date = isoDate.date(from: date) else { continue }
    let day = weekday.string(from: date)
    let weather = condition(code)
    tiles.append(
      #"<tile label="\#(day)" icon="\#(weather.icon)" title="\#(degrees(high)) \#(degrees(low))"/>"#)
    dailyLines.append("\(day) · \(weather.title) · H: \(degrees(high)) L: \(degrees(low))")
  }
  if !tiles.isEmpty {
    body.append("### Daily forecast\n<columns>\n" + tiles.joined(separator: "\n") + "\n</columns>")
    copy.append("Daily forecast\n" + dailyLines.joined(separator: "\n"))
  }

  if let hourly = forecast.hourly {
    var rows: [String] = []
    var hourlyLines: [String] = []
    for (time, (temperature, code)) in zip(hourly.time, zip(hourly.temperatures, hourly.weatherCode)) {
      guard time > forecast.current.time else { continue }
      let hour = time.dropFirst(11)
      guard hour.wholeMatch(of: /[0-9]{2}:[0-9]{2}/) != nil else { continue }
      let weather = condition(code)
      rows.append(#"<row label="\#(hour)" title="\#(weather.title)" value="\#(degrees(temperature))"/>"#)
      hourlyLines.append("\(hour) · \(weather.title) · \(degrees(temperature))")
    }
    if !rows.isEmpty {
      body.append("### Next hours\n" + rows.joined(separator: "\n"))
      copy.append("Next hours\n" + hourlyLines.joined(separator: "\n"))
    }
  }

  body.append("Weather data by [Open-Meteo](https://open-meteo.com/)")
  copy.append("Weather data by Open-Meteo")
  let text = quoted(copy.joined(separator: "\n\n"))
  return
    #"{"body":\#(quoted(body.joined(separator: "\n\n"))),"actions":[{"type":"copy","title":"Copy forecast","text":\#(text)}]}"#
}

private func whole(_ value: Double) -> String {
  let rounded = value.rounded()
  return String(format: "%.0f", rounded == 0 ? 0 : rounded)
}

private func degrees(_ value: Double?) -> String { value.map { whole($0) + "°" } ?? "—" }

func condition(_ code: Int?, night: Bool = false) -> (title: String, icon: String) {
  switch code {
  case 0: ("Clear", night ? "moon.stars" : "sun.max")
  case 1: ("Mostly clear", night ? "cloud.moon" : "cloud.sun")
  case 2: ("Partly cloudy", night ? "cloud.moon" : "cloud.sun")
  case 3: ("Overcast", "cloud")
  case 45, 48: ("Fog", "cloud.fog")
  case 51, 53, 55: ("Drizzle", "cloud.drizzle")
  case 56, 57: ("Freezing drizzle", "cloud.sleet")
  case 61, 63: ("Rain", "cloud.rain")
  case 65: ("Heavy rain", "cloud.heavyrain")
  case 66, 67: ("Freezing rain", "cloud.sleet")
  case 71, 73, 75, 77: ("Snow", "snowflake")
  case 80, 81, 82: ("Rain showers", "cloud.rain")
  case 85, 86: ("Snow showers", "cloud.snow")
  case 95: ("Thunderstorm", "cloud.bolt")
  case 97: ("Heavy thunderstorm", "cloud.bolt")
  case 96, 99: ("Thunderstorm with hail", "cloud.bolt.rain")
  default: ("Conditions unavailable", "cloud")
  }
}

extension JSON {
  fileprivate var isTrue: Bool {
    if case .bool(true) = self { true } else { false }
  }
}
