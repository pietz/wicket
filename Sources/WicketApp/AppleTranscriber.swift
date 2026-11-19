import AVFoundation
import Speech

/// Apple's macOS 26 on-device pipeline on the system's default input. No fallback recognizer, model
/// download or audio file.
@MainActor final class AppleTranscriber: Transcriber {
  private var task: Task<Void, Never>?
  private var microphone: Microphone?
  private(set) var shutdown: Task<Void, Never>?
  func start() -> AsyncThrowingStream<VoiceUpdate, any Error> {
    stop()
    let capture = Microphone()
    microphone = capture
    return AsyncThrowingStream { continuation in
      let worker = Task.detached(priority: .userInitiated) {
        do {
          try await Self.listen(
            capture, yield: { continuation.yield($0) }, fail: { continuation.finish(throwing: $0) })
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      task = worker
      // A conversion error can finish from the audio tap; run teardown away from that callback.
      continuation.onTermination = { _ in Task.detached { worker.cancel() } }
    }
  }
  func stop() {
    if let microphone { shutdown = microphone.stop() }
    microphone = nil
    task?.cancel()
    task = nil
  }
  nonisolated static func validateUsage(_ info: [String: Any]) throws {
    guard let text = info["NSMicrophoneUsageDescription"] as? String, !text.isEmpty else {
      throw VoiceError.usageMissing
    }
  }
  nonisolated private static func listen(
    _ microphone: Microphone, yield: @escaping @Sendable (VoiceUpdate) -> Void,
    fail: @escaping @Sendable (VoiceError) -> Void
  ) async throws {
    defer { _ = microphone.stop() }
    try validateUsage(Bundle.main.infoDictionary ?? [:])
    try Task.checkCancellation()
    let permission = AVAudioApplication.shared.recordPermission
    let micAllowed: Bool
    if permission == .undetermined {
      yield(.permission(true))
      micAllowed = await AVAudioApplication.requestRecordPermission()
      yield(.permission(false))
    } else {
      micAllowed = permission == .granted
    }
    try Task.checkCancellation()
    guard micAllowed else { throw VoiceError.microphoneDenied }
    guard SpeechTranscriber.isAvailable,
      let locale = VoiceLanguage.choose(
        preferred: Locale.preferredLanguages, supported: await SpeechTranscriber.supportedLocales)
    else { throw VoiceError.noLanguage }
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])
    guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
      throw VoiceError.modelMissing
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw VoiceError.noLanguage
    }
    try Task.checkCancellation()
    let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
    defer { feed.finish() }
    let analyzer = SpeechAnalyzer(
      modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      // Audio buffers from here on wait in `inputs` until the analyzer reads them: the first word counts.
      try microphone.start(format: format, feed: feed, firstAudio: { yield(.audio(.now)) }, fail: fail)
      yield(.ready)
      try await analyzer.start(inputSequence: inputs)
      var transcript = Transcript(locale: locale)
      for try await result in transcriber.results {
        try Task.checkCancellation()
        transcript.apply(String(result.text.characters), isFinal: result.isFinal)
        yield(.transcript(transcript.text))
      }
    } onCancel: {
      _ = microphone.stop()
      feed.finish()
      Task { await analyzer.cancelAndFinishNow() }
    }
  }
}

/// The capture of one listening session. One serial queue owns the engine: opening, a device change and
/// teardown run on it in order, so a stop during opening waits for it and nothing opens after a stop.
/// Opening runs on the caller's thread (never the main actor); stopping never blocks its caller.
final class Microphone: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.wicket.capture")
  private var engine: (any CaptureEngine)?
  private var observer: (any NSObjectProtocol)?
  private var started = false, stopped = false
  /// Set by the opening once its tap is installed, so closing removes it.
  var tapped = false
  private let opened = ContinuousClock.now

  /// Makes the engine and runs `body` with it on the queue, once, unless capture already stopped; a
  /// failure closes what it opened.
  func open<Engine: CaptureEngine>(_ make: @autoclosure () -> Engine, _ body: (Engine) throws -> Void) throws
  {
    try queue.sync {
      guard !stopped, !started else { throw CancellationError() }
      started = true
      let engine = make()
      self.engine = engine
      do { try body(engine) } catch {
        close()
        throw error
      }
    }
  }
  /// Stops capture for good. The close is queued before this returns, so no later opening gets in; the
  /// task ends once the engine is closed, after any opening in progress.
  func stop() -> Task<Void, Never> {
    let (closed, finish) = AsyncStream.makeStream(of: Never.self)
    queue.async { [self] in
      close()
      finish.finish()
    }
    return Task { for await _ in closed {} }
  }
  /// Configuration changes also arrive during a normal startup, Bluetooth especially: only one that leaves
  /// the engine stopped ends capture, with a hint, and nothing restarts by itself.
  func configurationChanged(fail: @escaping @Sendable (VoiceError) -> Void) {
    queue.async { [self] in
      guard !stopped, let engine, !engine.isRunning else { return }
      VoiceLog.logger.log(
        "voice input stopped by a configuration change \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after opening"
      )
      close()
      fail(.inputChanged)
    }
  }
  /// Opens the default input, taps it at the hardware's format and feeds `format` to the analyzer.
  func start(
    format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (VoiceError) -> Void
  ) throws {
    try open(AVAudioEngine()) { [self] engine in
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in self?.configurationChanged(fail: fail) }
      let input = engine.inputNode
      let tap = try Self.tapFormat(
        hardware: input.inputFormat(forBus: 0), node: input.outputFormat(forBus: 0))
      let conversion = try Conversion(input: tap, output: format)
      // A tap whose rate disagrees with the hardware raises an uncatchable exception: recheck just before.
      guard input.inputFormat(forBus: 0).sameRateAndChannels(tap) else { throw VoiceError.noMicrophone }
      nonisolated(unsafe) var received = false
      input.installTap(onBus: 0, bufferSize: 2048, format: tap) { buffer, _ in
        if !received {
          received = true
          firstAudio()
        }
        do {
          if let converted = try conversion.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
        } catch { fail(.conversionFailed) }
      }
      tapped = true
      // Starting with a node format that disagrees with the hardware raises the same exception.
      guard input.outputFormat(forBus: 0).sameRateAndChannels(tap) else { throw VoiceError.noMicrophone }
      engine.prepare()
      try engine.start()
    }
  }
  private func close() {
    stopped = true
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    if tapped { engine?.removeTap() }
    tapped = false
    engine?.stop()
    engine = nil
  }
  /// The input node cannot convert, so a tap must use the hardware's rate and channel count
  /// (AVAudioIONode.h); any other rate raises an exception Swift cannot catch. The node's own format
  /// is kept when it already agrees; otherwise it can be stale, as with a 32 kHz USB microphone
  /// whose node reported 48 kHz. Conversion resamples either one.
  static func tapFormat(hardware: AVAudioFormat, node: AVAudioFormat) throws -> AVAudioFormat {
    guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else {
      throw VoiceError.noMicrophone
    }
    if node.sameRateAndChannels(hardware), node.commonFormat == .pcmFormatFloat32, !node.isInterleaved {
      return node
    }
    let format =
      hardware.channelLayout.map {
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, interleaved: false,
          channelLayout: $0)
      } ?? AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
    guard let format, format.sameRateAndChannels(hardware) else { throw VoiceError.noMicrophone }
    return format
  }
}

/// What closing needs from the engine; tests count it with a fake.
protocol CaptureEngine: AnyObject {
  var isRunning: Bool { get }
  func removeTap()
  func stop()
}

extension AVAudioEngine: CaptureEngine {
  func removeTap() { inputNode.removeTap(onBus: 0) }
}

/// AVAudioEngine supplies Float32 PCM; explicit averaging also supports discrete multichannel layouts.
final class Conversion: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let source: AVAudioFormat, mono: AVAudioFormat, format: AVAudioFormat
  private let ratio: Double
  init(input: AVAudioFormat, output: AVAudioFormat) throws {
    guard input.commonFormat == .pcmFormatFloat32,
      let mono = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 1),
      let converter = AVAudioConverter(from: input.channelCount > 1 ? mono : input, to: output)
    else { throw VoiceError.conversionFailed }
    source = input
    self.mono = mono
    self.converter = converter
    format = output
    ratio = output.sampleRate / input.sampleRate
  }
  func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    // Not ==: that also compares channel layouts, which do not affect averaging or resampling.
    guard buffer.format.sameRateAndChannels(source), buffer.format.commonFormat == source.commonFormat,
      buffer.format.isInterleaved == source.isInterleaved
    else { throw VoiceError.conversionFailed }
    guard buffer.frameLength > 0 else { return nil }
    var input = buffer
    if source.channelCount > 1 {
      guard let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
        let channels = buffer.floatChannelData, let samples = mixed.floatChannelData?[0]
      else { throw VoiceError.conversionFailed }
      mixed.frameLength = buffer.frameLength
      let count = Int(source.channelCount)
      for frame in 0..<Int(buffer.frameLength) {
        var sum: Float = 0
        for channel in 0..<count {
          sum += source.isInterleaved ? channels[0][frame * count + channel] : channels[channel][frame]
        }
        samples[frame] = sum / Float(count)
      }
      input = mixed
    }
    let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw VoiceError.conversionFailed
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error, withInputFrom: Self.inputBlock(input))
    guard status != .error else { throw VoiceError.conversionFailed }
    return output.frameLength > 0 ? output : nil
  }
  static func inputBlock(_ buffer: AVAudioPCMBuffer) -> AVAudioConverterInputBlock {
    nonisolated(unsafe) var supplied = false
    // AVAudioPCMBuffer is Sendable only from the macOS 27 SDK; the converter calls this block synchronously.
    nonisolated(unsafe) let buffer = buffer
    return { _, status in
      guard !supplied else {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
  }
}

extension AVAudioFormat {
  fileprivate func sameRateAndChannels(_ other: AVAudioFormat) -> Bool {
    sampleRate == other.sampleRate && channelCount == other.channelCount
  }
}

/// Prefer the user's region, then the language's likely region, then any supported region.
enum VoiceLanguage {
  static func choose(preferred: [String], supported: [Locale]) -> Locale? {
    for identifier in preferred {
      let wanted = Locale(identifier: identifier)
      guard let language = wanted.language.languageCode else { continue }
      let likely = Locale(identifier: Locale.Language(identifier: language.identifier).maximalIdentifier)
      let candidates = supported.filter { $0.language.languageCode == language }
      for region in [wanted.region, likely.region].compactMap(\.self) {
        if let match = candidates.first(where: { $0.region == region }) { return match }
      }
      if let any = candidates.first { return any }
    }
    return nil
  }
}
