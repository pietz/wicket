import Foundation

let weatherUnavailable = message("Weather unavailable. Try again.")

func weatherView(_ request: JSON?, fetch: @escaping (URL) async throws -> Data) async -> String {
  if request?["rootMatch"]?.isTrue == true { return #"{"items":[]}"# }

  let settings = request?["settings"]
  let input = request?["fields"]?["city"]?.string ?? request?["input"]?.string ?? ""
  let typedCity = input.trimmingCharacters(in: .whitespacesAndNewlines)
  let defaultCity = settings?["defaultCity"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let city = typedCity.isEmpty ? defaultCity : typedCity

  guard !city.isEmpty else { return message("Type a city, or set Default city in Settings") }
  guard request?["submitted"]?.isTrue == true else {
    return message(
      typedCity.isEmpty ? "Press Return for the default city's forecast" : "Press Return for the forecast")
  }

  let fahrenheit = settings?["units"]?.string == "Fahrenheit"
  let api = OpenMeteo(fetch: fetch)
  do {
    guard let place = try await api.place(named: city) else { return message("City not found") }
    let forecast = try await api.forecast(for: place, fahrenheit: fahrenheit)
    let current = forecast.current
    let weather = condition(current.weatherCode, night: current.isDay == 0)
    let title = "\(degrees(current.temperature))\(fahrenheit ? "F" : "C") · \(weather.title)"
    let high = degrees(forecast.daily.highs.first ?? nil)
    let low = degrees(forecast.daily.lows.first ?? nil)
    let details =
      "Feels like \(degrees(current.apparentTemperature)) · H: \(high) L: \(low) · Wind \(whole(current.windSpeed)) km/h"
    return forecastPage(title: title, location: place.location, details: details, forecast: forecast)
  } catch {
    return weatherUnavailable
  }
}

private func message(_ title: String) -> String { #"{"body":\#(quoted(title))}"# }

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
      guard hour.wholeMatch(of: #/[0-9]{2}:[0-9]{2}/#) != nil else { continue }
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
