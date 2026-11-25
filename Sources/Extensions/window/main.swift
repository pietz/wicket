MainActor.assumeIsolated {
  if let view = windowAnswer(
    JSON.standardInput(), manifestBytes: contents("wicket.json") ?? [],
    move: { perform($0, layout: $1, commandName: $2) },
    capture: captureWindows)
  {
    print(view)
  }
}
