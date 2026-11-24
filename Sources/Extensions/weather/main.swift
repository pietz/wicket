// Rebuild a copy with swiftc -O *.swift -o main.
import Foundation

func runWeather() async -> String {
  let request = JSON.standardInput()
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = 4
  config.timeoutIntervalForResource = 4
  config.urlCache = nil
  let session = URLSession(configuration: config)
  defer { session.invalidateAndCancel() }
  return await weatherView(request) { url in
    let (data, response) = try await session.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
  }
}

print(await runWeather())
