import Foundation

private struct Rate: Decodable {
  let base: String
  let quote: String
  let rate: Double
}

func exchangeRate(from source: String, to target: String) async -> Double? {
  if source == target { return 1 }
  let data: Data
  if let fixture = ProcessInfo.processInfo.environment["WICKET_CONVERT_RATE_JSON"] {
    data = Data(fixture.utf8)
  } else {
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    guard let url = URL(string: "https://api.frankfurter.dev/v2/rate/\(source)/\(target)"),
      let (responseData, response) = try? await session.data(
        for: URLRequest(url: url, timeoutInterval: 4)),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    data = responseData
  }
  guard let rate = try? JSONDecoder().decode(Rate.self, from: data),
    rate.base == source, rate.quote == target, rate.rate.isFinite, rate.rate > 0
  else { return nil }
  return rate.rate
}
