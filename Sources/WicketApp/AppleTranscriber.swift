import AVFoundation
import CoreAudio
import CoreMedia
import Speech
import Synchronization

/// Apple's macOS 26 on-device pipeline. No fallback recognizer, model download or audio file.
@MainActor final class AppleTranscriber: Transcriber {
  private var task: Task<Void, Never>?
  private var microphone: Microphone?
  private(set) var shutdown: AsyncStream<Never>?
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
      yield(.openingMicrophone(.now))
      try await microphone.start(
        format: format, audio: { feed.yield(AnalyzerInput(buffer: $0)) },
        firstAudio: { yield(.audio(.now)) }, fail: fail)
      try Task.checkCancellation()
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

/// Each capture has its own queue so a stalled teardown cannot block the next session.
final class Microphone: @unchecked Sendable {
  private static let hardwareOpen = DispatchSemaphore(value: 1)
  private let openSlot: DispatchSemaphore
  private let queue = DispatchQueue(label: "app.wicket.capture", qos: .userInitiated)
  private var session: (any CaptureSession)?
  private var samples: AudioSamples?
  private var observers: [any NSObjectProtocol] = []
  private let stopped = Atomic(false)
  private let opened = ContinuousClock.now

  init(openSlot: DispatchSemaphore = Microphone.hardwareOpen) {
    self.openSlot = openSlot
  }

  private var isStopped: Bool { stopped.load(ordering: .relaxed) }

  func open<Device>(
    selecting select: @escaping @Sendable () throws -> Device,
    session make: @escaping @Sendable (Device) throws -> any CaptureSession
  ) async throws {
    let (opened, result) = AsyncThrowingStream<Never, any Error>.makeStream()
    queue.async { [self] in
      guard !isStopped, session == nil else {
        result.finish(throwing: CancellationError())
        return
      }
      // Fail fast while a previous call into the driver is still outstanding.
      guard openSlot.wait(timeout: .now()) == .success else {
        result.finish(throwing: VoiceError.microphoneStartFailed)
        return
      }
      let outcome = Swift.Result<Void, any Error> {
        defer { openSlot.signal() }
        let device = try select()
        guard !isStopped else { throw CancellationError() }
        let capture = try make(device)
        guard !isStopped else { throw CancellationError() }
        capture.startRunning()
        session = capture
        guard !isStopped else { throw CancellationError() }
        guard capture.isRunning else { throw VoiceError.microphoneStartFailed }
      }
      switch outcome {
      case .success: result.finish()
      case .failure(let error):
        close()
        result.finish(throwing: error)
      }
    }
    // Cancelling speech releases its wait even if the system call on the queue has not returned.
    for try await _ in opened {}
    try Task.checkCancellation()
  }

  /// Set cancellation now so an opening stalled on the queue can see it before starting the capture.
  func stop() -> AsyncStream<Never> {
    stopped.store(true, ordering: .relaxed)
    let (closed, finish) = AsyncStream.makeStream(of: Never.self)
    queue.async { [self] in
      close()
      finish.finish()
    }
    return closed
  }

  func captureEnded(fail: @escaping @Sendable (VoiceError) -> Void) {
    queue.async { [self] in
      guard !isStopped else { return }
      VoiceLog.logger.log(
        "voice input stopped by a configuration change \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after opening"
      )
      fail(.inputChanged)
      close()
    }
  }

  func start(
    format: AVAudioFormat, audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (VoiceError) -> Void
  ) async throws {
    // An explicit device input avoids AVAudioEngine binding its default input and switching it back.
    try await open(selecting: InputDevice.select) { [self] device in
      let capture = AVCaptureSession()
      let input = try AVCaptureDeviceInput(device: device)
      let output = AVCaptureAudioDataOutput()
      let samples = AudioSamples(format: format, audio: audio, firstAudio: firstAudio, fail: fail)
      output.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
      ]
      // Session startup and teardown can wait for delivery to drain.
      output.setSampleBufferDelegate(
        samples, queue: DispatchQueue(label: "app.wicket.audio", qos: .userInitiated))
      guard capture.canAddInput(input) else { throw VoiceError.noMicrophone }
      capture.addInput(input)
      guard capture.canAddOutput(output) else { throw VoiceError.microphoneStartFailed }
      capture.addOutput(output)
      self.samples = samples
      observers = [
        observe(AVCaptureSession.didStopRunningNotification, object: capture, fail: fail),
        observe(AVCaptureSession.runtimeErrorNotification, object: capture, fail: fail),
        observe(AVCaptureDevice.wasDisconnectedNotification, object: device, fail: fail),
      ]
      return capture
    }
  }

  private func observe(
    _ name: Notification.Name, object: AnyObject, fail: @escaping @Sendable (VoiceError) -> Void
  ) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
      self?.captureEnded(fail: fail)
    }
  }

  private func close() {
    stopped.store(true, ordering: .relaxed)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    session?.stopRunning()
    session = nil
    samples = nil
  }
}

/// The session lifecycle, exercised with a fake instead of opening hardware.
protocol CaptureSession: AnyObject {
  var isRunning: Bool { get }
  func startRunning()
  func stopRunning()
}

extension AVCaptureSession: CaptureSession {}

/// A Bluetooth microphone switches its headset into call mode, degrading playback. Prefer built-in
/// then USB when the default is Bluetooth.
enum InputDevice {
  static func select() throws -> AVCaptureDevice {
    try select(
      current: AVCaptureDevice.default(for: .audio),
      discover: { AVCaptureDevice.DiscoverySession(deviceTypes: $0, mediaType: $1, position: $2).devices },
      transport: { UInt32(bitPattern: $0.transportType) })
  }

  static func select<Device>(
    current: Device?,
    discover: ([AVCaptureDevice.DeviceType], AVMediaType, AVCaptureDevice.Position) -> [Device],
    transport: (Device) -> UInt32
  ) throws -> Device {
    guard let current else { throw VoiceError.noMicrophone }
    guard
      [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(current))
    else { return current }
    let candidates = discover([.microphone, .external], .audio, .unspecified)
    return candidates.first { transport($0) == kAudioDeviceTransportTypeBuiltIn }
      ?? candidates.first { transport($0) == kAudioDeviceTransportTypeUSB } ?? current
  }
}

/// All sample delivery and conversion run in order on the output's delegate queue.
final class AudioSamples: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let format: AVAudioFormat
  private let audio: @Sendable (AVAudioPCMBuffer) -> Void
  private let firstAudio: @Sendable () -> Void
  private let fail: @Sendable (VoiceError) -> Void
  private var conversion: Conversion?

  init(
    format: AVAudioFormat, audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (VoiceError) -> Void
  ) {
    self.format = format
    self.audio = audio
    self.firstAudio = firstAudio
    self.fail = fail
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    receive(sampleBuffer)
  }

  func receive(_ sampleBuffer: CMSampleBuffer) {
    do {
      guard sampleBuffer.numSamples > 0 else { return }
      guard let description = sampleBuffer.formatDescription,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
          frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
      else { throw VoiceError.conversionFailed }
      buffer.frameLength = buffer.frameCapacity
      try sampleBuffer.copyPCMData(
        fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
      if conversion == nil {
        firstAudio()
        conversion = try Conversion(input: buffer.format, output: format)
      }
      if let converted = try conversion?.convert(buffer) { audio(converted) }
    } catch { fail(.conversionFailed) }
  }
}

/// Explicit averaging supports discrete multichannel PCM layouts.
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
