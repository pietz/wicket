import Foundation

let weatherUnavailable = message("Weather unavailable. Try again.")
let noWeatherItems = #"{"items":[]}"#

func weatherView(
  _ request: JSON?, cacheDirectory: URL? = nil, fetch: @escaping (URL) async throws -> Data
) async -> String {
  let rootMatch = request?["rootMatch"]?.isTrue == true
  let settings = request?["settings"]
  let input = request?["fields"]?["city"]?.string ?? request?["input"]?.string ?? ""
  let typedCity = input.trimmingCharacters(in: .whitespacesAndNewlines)
  let city: String
  if rootMatch {
    let parts = typedCity.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard parts.count == 2, parts[0].lowercased() == "weather" else { return noWeatherItems }
    city = String(parts[1])
    let name = cityWithoutIn(city) ?? city
    guard name.filter({ !$0.isWhitespace }).count >= 4 else { return noWeatherItems }
  } else {
    let defaultCity = settings?["defaultCity"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    city = typedCity.isEmpty ? defaultCity : typedCity
    guard !city.isEmpty else { return message("Type a city, or set Default city in Settings") }
    guard request?["submitted"]?.isTrue == true else {
      return message(
        typedCity.isEmpty ? "Press Return for the default city's forecast" : "Press Return for the forecast")
    }
  }

  let fahrenheit = settings?["units"]?.string == "Fahrenheit"
  let api = OpenMeteo(cacheDirectory: cacheDirectory, fetch: fetch)
  do {
    guard let place = try await api.place(named: city) else {
      return rootMatch ? noWeatherItems : message("City not found")
    }
    let forecast = try await api.forecast(for: place, fahrenheit: fahrenheit)
    let current = forecast.current
    let weather = condition(current.weatherCode, night: current.isDay == 0)
    let temperature = "\(degrees(current.temperature))\(fahrenheit ? "F" : "C")"
    let high = degrees(forecast.daily.highs.first ?? nil)
    let low = degrees(forecast.daily.lows.first ?? nil)
    let range = "H: \(high) L: \(low)"
    if rootMatch {
      let title = "\(place.name) · \(temperature), \(weather.title.lowercased())"
      return #"""
        {"items":[{"id":"weather","title":\#(quoted(title)),"subtitle":\#(quoted(range)),
        "icon":\#(quoted(weather.icon)),"prominent":true,"actions":[
        {"type":"run","title":"Show Forecast","fields":{"city":\#(quoted(city))}}]}]}
        """#
    }
    let title = "\(degrees(current.temperature)) \(weather.title)"
    let wind = "\(whole(current.windSpeed)) km/h"
    let details = "H \(high) L \(low) · Feels like \(degrees(current.apparentTemperature)) · Wind \(wind)"
    return forecastPage(
      title: title, copyTitle: "\(temperature) \(weather.title)", location: place.location,
      details: details, forecast: forecast)
  } catch {
    return rootMatch ? noWeatherItems : weatherUnavailable
  }
}

private func message(_ title: String) -> String { #"{"body":\#(quoted(title))}"# }

private func forecastPage(
  title: String, copyTitle: String, location: String, details: String, forecast: Forecast
) -> String {
  // Escape Markdown punctuation and squeeze line breaks so place names stay plain text.
  let place = location.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  let syntax = CharacterSet(charactersIn: "!\"#&'()*+-.<>[\\]_`{|}~:")
  let literal = place.unicodeScalars.map {
    syntax.contains($0) ? "&#\($0.value);" : String($0)
  }.joined()
  var body = ["# \(title)", "\(literal) · \(details)"]
  var copy = [copyTitle, "\(place) · \(details)"]

  let offset = TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .gmt
  let format = DateFormatter()
  format.locale = Locale(identifier: "en_US_POSIX")
  format.timeZone = TimeZone(identifier: forecast.timezone) ?? offset
  format.dateFormat = "HH:mm"
  if let hourly = forecast.hourly, let first = hourly.time.firstIndex(where: { $0 > forecast.current.time }) {
    var tiles: [String] = []
    var hourlyLines: [String] = []
    for index in stride(from: first, to: min(hourly.time.count, first + 12), by: 2) {
      let date = Date(timeIntervalSince1970: hourly.time[index])
      let hour = format.string(from: date)
      let temperature = degrees(hourly.temperatures[ifPresent: index] ?? nil)
      let weather = condition(
        hourly.weatherCode[ifPresent: index] ?? nil, night: hourly.isDay[ifPresent: index] == 0)
      let chance = hourly.precipitationProbability[ifPresent: index] ?? nil
      let precipitation = chance.flatMap { $0 >= 20 ? "\($0)%" : nil }
      let subtitle = precipitation.map { #" subtitle="\#($0)""# } ?? ""
      tiles.append(#"<tile label="\#(hour)" icon="\#(weather.icon)" title="\#(temperature)"\#(subtitle)/>"#)
      let rain = precipitation.map { " · \($0) precipitation" } ?? ""
      hourlyLines.append("\(hour) · \(weather.title) · \(temperature)\(rain)")
    }
    body.append("### Next hours\n<columns>\n" + tiles.joined(separator: "\n") + "\n</columns>")
    copy.append("Next hours\n" + hourlyLines.joined(separator: "\n"))
  }

  let daily = forecast.daily
  // Open-Meteo defines daily boundaries using the offset it reports at request time.
  format.timeZone = offset
  format.dateFormat = "EEE"
  let days = zip(daily.time, zip(daily.highs, daily.lows))
  var tiles: [String] = []
  var dailyLines: [String] = []
  for ((date, (high, low)), code) in zip(days, daily.weatherCode) {
    let day = format.string(from: Date(timeIntervalSince1970: date))
    let weather = condition(code)
    tiles.append(
      #"<tile label="\#(day)" icon="\#(weather.icon)" title="↑\#(degrees(high)) ↓\#(degrees(low))"/>"#)
    dailyLines.append("\(day) · \(weather.title) · H: \(degrees(high)) L: \(degrees(low))")
  }
  if !tiles.isEmpty {
    body.append("### Next days\n<columns>\n" + tiles.joined(separator: "\n") + "\n</columns>")
    copy.append("Next days\n" + dailyLines.joined(separator: "\n"))
  }

  copy.append("Weather data by Open-Meteo")
  let text = quoted(copy.joined(separator: "\n\n"))
  return #"""
    {"body":\#(quoted(body.joined(separator: "\n\n"))),"actions":[
    {"type":"copy","title":"Copy forecast","text":\#(text)},
    {"type":"open","title":"Weather data by Open-Meteo","url":"https://open-meteo.com/"}]}
    """#
}

extension Array {
  fileprivate subscript(ifPresent index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
  var isTrue: Bool {
    if case .bool(true) = self { true } else { false }
  }
}
