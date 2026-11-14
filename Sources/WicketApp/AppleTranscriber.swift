import AVFoundation
import Speech

/// Apple's macOS 26 on-device pipeline. No fallback recognizer, model download or audio file.
@MainActor final class AppleTranscriber: Transcriber {
  var microphoneUID: String?
  init(microphoneUID: String? = nil) { self.microphoneUID = microphoneUID }
  private var task: Task<Void, Never>?
  private var microphone: Microphone?
  private(set) var shutdown: Task<Void, Never>?
  func start() -> AsyncThrowingStream<VoiceUpdate, any Error> {
    stop()
    let capture = Microphone()
    let uid = microphoneUID
    microphone = capture
    return AsyncThrowingStream { continuation in
      let worker = Task.detached(priority: .userInitiated) {
        do {
          VoiceLog.logger.log(
            "voice transcriber starting, microphone chosen in Settings: \(uid?.isEmpty == false, privacy: .public)"
          )
          try await Self.listen(
            capture, uid: uid, yield: { continuation.yield($0) }, fail: { continuation.finish(throwing: $0) })
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      task = worker
      // A conversion error can finish from the audio tap; run teardown away from that callback.
      continuation.onTermination = { _ in Task.detached { worker.cancel() } }
    }
  }
  func stop() {
    if let microphone { shutdown = microphone.requestStop() }
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
    _ microphone: Microphone, uid: String?, yield: @escaping @Sendable (VoiceUpdate) -> Void,
    fail: @escaping @Sendable (VoiceError) -> Void
  ) async throws {
    defer { _ = microphone.requestStop() }
    try validateUsage(Bundle.main.infoDictionary ?? [:])
    try Task.checkCancellation()
    let permission = AVAudioApplication.shared.recordPermission
    VoiceLog.logger.log(
      "voice permissions: record \(String(describing: permission.kind), privacy: .public), capture \(String(describing: AVCaptureDevice.authorizationStatus(for: .audio).kind), privacy: .public), speech \(String(describing: SFSpeechRecognizer.authorizationStatus().kind), privacy: .public)"
    )
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
    guard SpeechTranscriber.isAvailable else {
      VoiceLog.logger.error("voice: SpeechTranscriber unavailable")
      throw VoiceError.noLanguage
    }
    guard
      let locale = VoiceLanguage.choose(
        preferred: Locale.preferredLanguages, supported: await SpeechTranscriber.supportedLocales
      )
    else {
      VoiceLog.logger.error("voice: no supported preferred language")
      throw VoiceError.noLanguage
    }
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])
    guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
      throw VoiceError.modelMissing
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      VoiceLog.logger.error("voice: no analyzer audio format")
      throw VoiceError.noLanguage
    }
    try Task.checkCancellation()
    let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
    defer { feed.finish() }
    let analyzer = SpeechAnalyzer(
      modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
    try await withTaskCancellationHandler {
      try microphone.start(
        format: format, uid: uid, feed: feed, firstAudio: { yield(.audio(.now)) }, fail: fail)
      yield(.ready)
      try await analyzer.start(inputSequence: inputs)
      var transcript = Transcript(locale: locale)
      for try await result in transcriber.results {
        try Task.checkCancellation()
        transcript.apply(String(result.text.characters), isFinal: result.isFinal)
        yield(.transcript(transcript.text))
      }
    } onCancel: {
      _ = microphone.requestStop()
      feed.finish()
      Task { await analyzer.cancelAndFinishNow() }
    }
  }
}

/// Opening never holds the state lock. Completion waits off the main actor for opening and teardown.
final class Microphone: @unchecked Sendable {
  private let lock = NSLock()
  private var close: (@Sendable () -> Void)?
  private var stopped = false, started = false
  private var shutdown: Task<Void, Never>?
  private let opening: AsyncStream<Void>
  private let finished: AsyncStream<Void>.Continuation
  init() { (opening, finished) = AsyncStream.makeStream(of: Void.self) }
  func start(open: () throws -> @Sendable () -> Void) throws {
    try lock.withLock {
      guard !stopped, !started else { throw CancellationError() }
      started = true
    }
    defer { finished.finish() }
    let close = try open()
    lock.withLock { self.close = close }
  }
  func start(
    format: AVAudioFormat, uid: String?, feed: AsyncStream<AnalyzerInput>.Continuation,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (VoiceError) -> Void
  ) throws {
    try start {
      let capture = EngineCapture(format: format, uid: uid, feed: feed, firstAudio: firstAudio, fail: fail)
      try capture.start()
      return { capture.stop() }
    }
  }
  func requestStop() -> Task<Void, Never> {
    lock.withLock {
      stopped = true
      if !started { finished.finish() }
      if let shutdown { return shutdown }
      let task = Task.detached { [self] in
        for await _ in opening {}
        let close = lock.withLock {
          let value = self.close
          self.close = nil
          return value
        }
        close?()
      }
      shutdown = task
      return task
    }
  }
  static func validate(input: AVAudioFormat, output: AVAudioFormat) throws {
    guard input.sampleRate.isFinite, input.sampleRate > 0, input.channelCount > 0,
      output.sampleRate.isFinite, output.sampleRate > 0, output.channelCount > 0,
      input == output
    else { throw VoiceError.noMicrophone }
  }
  func stop() async { await requestStop().value }
}

/// Serialize engine changes and teardown, including notifications queued during startup.
private final class EngineCapture: @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.wicket.capture")
  private let engine = AVAudioEngine()
  private var observer: (any NSObjectProtocol)?
  private var tapped = false, stopped = false
  private let format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation
  private let fail: @Sendable (VoiceError) -> Void
  private let uid: String?, firstAudio: @Sendable () -> Void
  private let opened = ContinuousClock.now
  init(
    format: AVAudioFormat, uid: String?, feed: AsyncStream<AnalyzerInput>.Continuation,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (VoiceError) -> Void
  ) {
    self.format = format
    self.uid = uid
    self.feed = feed
    self.firstAudio = firstAudio
    self.fail = fail
  }
  func start() throws {
    try queue.sync {
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in
        guard let self else { return }
        queue.async { [self] in
          VoiceLog.logger.log(
            "voice engine configuration change, \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after opening; stopped \(self.stopped, privacy: .public), running \(self.engine.isRunning, privacy: .public)"
          )
          guard !stopped else { return }
          guard !engine.isRunning else { return }
          close()
          fail(.inputChanged)
        }
      }
      do { try open() } catch {
        close()
        throw error
      }
    }
  }
  private func open() throws {
    let input = engine.inputNode
    let devices = MicrophoneDevices.available()
    let defaultInput = devices.first(where: \.isDefault)
    VoiceLog.logger.log(
      "voice inputs: \(devices.count, privacy: .public), system default \(defaultInput?.kind ?? "none", privacy: .public), chosen in Settings and present: \(devices.contains { $0.uid == self.uid }, privacy: .public)"
    )
    guard let device = MicrophoneDevice.select(devices, uid: uid) else {
      VoiceLog.logger.error("voice: no usable input device")
      throw VoiceError.noMicrophone
    }
    VoiceLog.logger.log(
      "voice device: \(device.kind, privacy: .public), system default \(device.isDefault, privacy: .public), chosen in Settings \(device.uid == self.uid, privacy: .public)"
    )
    do { try input.auAudioUnit.setDeviceID(device.id) } catch {
      VoiceLog.logger.error("voice: setDeviceID failed: \(VoiceLog.describe(error), privacy: .public)")
      throw VoiceError.noMicrophone
    }
    let inputFormat = input.outputFormat(forBus: 0)
    let hardware = input.inputFormat(forBus: 0)
    VoiceLog.logger.log(
      "voice formats: hardware \(hardware.sampleRate, privacy: .public) Hz \(hardware.channelCount, privacy: .public) ch, node \(inputFormat.sampleRate, privacy: .public) Hz \(inputFormat.channelCount, privacy: .public) ch, equal \(hardware == inputFormat, privacy: .public)"
    )
    try Microphone.validate(input: hardware, output: inputFormat)
    let conversion = try Conversion(input: inputFormat, output: format)
    nonisolated(unsafe) var received = false
    input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [feed, fail, firstAudio] buffer, _ in
      if !received {
        received = true
        firstAudio()
      }
      do {
        if let converted = try conversion.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
      } catch {
        VoiceLog.logger.error("voice: conversion failed")
        fail(.conversionFailed)
      }
    }
    tapped = true
    engine.prepare()
    do { try engine.start() } catch {
      VoiceLog.logger.error("voice: engine start failed: \(VoiceLog.describe(error), privacy: .public)")
      throw error
    }
  }
  private func close() {
    stopped = true
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    if tapped {
      engine.inputNode.removeTap(onBus: 0)
      tapped = false
    }
    engine.stop()
  }
  func stop() { queue.sync { close() } }
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
    guard buffer.format == source else { throw VoiceError.conversionFailed }
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

extension AVAudioApplication.recordPermission {
  fileprivate var kind: String {
    switch self {
    case .granted: "granted"
    case .denied: "denied"
    case .undetermined: "undetermined"
    @unknown default: "unknown"
    }
  }
}
extension AVAuthorizationStatus {
  fileprivate var kind: String {
    switch self {
    case .authorized: "authorized"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "notDetermined"
    @unknown default: "unknown"
    }
  }
}
extension SFSpeechRecognizerAuthorizationStatus {
  fileprivate var kind: String {
    switch self {
    case .authorized: "authorized"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "notDetermined"
    @unknown default: "unknown"
    }
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
