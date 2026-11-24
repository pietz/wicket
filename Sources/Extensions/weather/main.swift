// Rebuild a copy with swiftc -O *.swift -o main.
import Foundation

func runWeather() async -> String {
  let request = JSON.standardInput()
  let config = URLSessionConfiguration.ephemeral
  config.urlCache = nil
  let session = URLSession(configuration: config)
  defer { session.invalidateAndCancel() }
  let cacheDirectory = ProcessInfo.processInfo.environment["WICKET_DATA_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
  let timeout = request?["rootMatch"]?.isTrue == true ? noWeatherItems : weatherUnavailable
  // Geocoding, its optional retry, and the forecast share one deadline inside Wicket's 10 s budget.
  let deadline = ContinuousClock.now + .seconds(7)
  return await withTaskGroup(of: String.self) { group in
    group.addTask {
      await weatherView(request, cacheDirectory: cacheDirectory) { url in
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
      }
    }
    group.addTask {
      try? await Task.sleep(until: deadline, clock: .continuous)
      return timeout
    }
    defer { group.cancelAll() }
    return await group.next() ?? timeout
  }
}

print(await runWeather())
