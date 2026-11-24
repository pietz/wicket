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
  func start(allowBluetooth: Bool) -> AsyncThrowingStream<VoiceUpdate, any Error> {
    stop()
    let capture = Microphone()
    microphone = capture
    return AsyncThrowingStream { continuation in
      let worker = Task.detached(priority: .userInitiated) {
        do {
          try await Self.listen(
            capture, allowBluetooth: allowBluetooth,
            yield: { continuation.yield($0) }, fail: { continuation.finish(throwing: $0) })
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
    _ microphone: Microphone, allowBluetooth: Bool, yield: @escaping @Sendable (VoiceUpdate) -> Void,
    fail: @escaping @Sendable (any Error) -> Void
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
        allowBluetooth: allowBluetooth, format: format, audio: { feed.yield(AnalyzerInput(buffer: $0)) },
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
        guard !isStopped else {
          capture.detach()
          throw CancellationError()
        }
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

  func captureEnded(error: NSError? = nil, fail: @escaping @Sendable (any Error) -> Void) {
    queue.async { [self] in
      guard !isStopped else { return }
      VoiceLog.logger.log(
        "voice input stopped by a configuration change \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after opening"
      )
      if let error {
        fail(VoiceSystemError(category: .inputChanged, domain: error.domain, code: error.code))
      } else {
        fail(VoiceError.inputChanged)
      }
      close()
    }
  }

  func start(
    allowBluetooth: Bool, format: AVAudioFormat, audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (any Error) -> Void
  ) async throws {
    // An explicit device input avoids AVAudioEngine binding its default input and switching it back.
    let select = { @Sendable in try InputDevice.select(allowBluetooth: allowBluetooth) }
    try await open(selecting: select) { [self] device in
      let capture = AVCaptureSession()
      let input = try AVCaptureDeviceInput(device: device)
      let output = AVCaptureAudioDataOutput()
      // Keep capture in native PCM. Convert once the actual sample format is known.
      output.audioSettings = nil
      guard capture.canAddInput(input) else { throw VoiceError.noMicrophone }
      capture.addInput(input)
      guard capture.canAddOutput(output) else { throw VoiceError.microphoneStartFailed }
      capture.addOutput(output)
      let samples = AudioSamples(format: format, audio: audio, firstAudio: firstAudio, fail: fail)
      // Session startup and teardown can wait for delivery to drain.
      output.setSampleBufferDelegate(
        samples, queue: DispatchQueue(label: "app.wicket.audio", qos: .userInitiated))
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
    _ name: Notification.Name, object: AnyObject, fail: @escaping @Sendable (any Error) -> Void
  ) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
      [weak self] notification in
      self?.captureEnded(error: notification.userInfo?[AVCaptureSessionErrorKey] as? NSError, fail: fail)
    }
  }

  private func close() {
    stopped.store(true, ordering: .relaxed)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    session?.stopRunning()
    session?.detach()
    session = nil
    samples = nil
  }
}

/// The session lifecycle, exercised with a fake instead of opening hardware.
protocol CaptureSession: AnyObject {
  var isRunning: Bool { get }
  func startRunning()
  func stopRunning()
  func detach()
}

extension AVCaptureSession: CaptureSession {
  func detach() {
    // stopRunning must happen outside the configuration transaction.
    beginConfiguration()
    for output in outputs {
      (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
      removeOutput(output)
    }
    for input in inputs { removeInput(input) }
    commitConfiguration()
  }
}

/// A Bluetooth microphone switches its headset into call mode, degrading playback.
enum InputDevice {
  static func select(allowBluetooth: Bool) throws -> AVCaptureDevice {
    let selected = try select(
      current: AVCaptureDevice.default(for: .audio), allowBluetooth: allowBluetooth,
      discover: { AVCaptureDevice.DiscoverySession(deviceTypes: $0, mediaType: $1, position: $2).devices },
      transport: { transport(uid: $0.uniqueID, captureTransport: UInt32(bitPattern: $0.transportType)) })
    let bytes = withUnsafeBytes(of: selected.transport.bigEndian) { Array($0) }
    let category =
      bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : "unknown"
    VoiceLog.logger.log("voice input transport: \(category, privacy: .public)")
    return selected.device
  }

  static func select<Device>(
    current: Device?, allowBluetooth: Bool,
    discover: ([AVCaptureDevice.DeviceType], AVMediaType, AVCaptureDevice.Position) -> [Device],
    transport: (Device) -> UInt32
  ) throws -> (device: Device, transport: UInt32) {
    guard let current else { throw VoiceError.noMicrophone }
    let currentTransport = transport(current)
    let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
      .contains(currentTransport)
    // An aggregate or unidentified default may route a Bluetooth mic, so a verified mic wins over it.
    let unverified = [
      kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate,
      kAudioDeviceTransportTypeUnknown,
    ].contains(currentTransport)
    guard bluetooth || unverified else { return (current, currentTransport) }
    let candidates = discover([.microphone, .external], .audio, .unspecified)
      .map { (device: $0, transport: transport($0)) }
    if let replacement = candidates.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn })
      ?? candidates.first(where: { $0.transport == kAudioDeviceTransportTypeUSB })
      ?? candidates.first(where: { isNonBluetoothHardware($0.transport) })
    {
      return replacement
    }
    guard allowBluetooth || !bluetooth else { throw VoiceError.bluetoothOnly }
    return (current, currentTransport)
  }

  private static func isNonBluetoothHardware(_ transport: UInt32) -> Bool {
    switch transport {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
      kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
      false
    default: true
    }
  }

  static func transport(
    uid: String, captureTransport: UInt32, coreAudio: (String) -> UInt32? = coreAudioTransport
  ) -> UInt32 {
    guard let transport = coreAudio(uid), transport != kAudioDeviceTransportTypeUnknown else {
      return captureTransport
    }
    return transport
  }

  private static func coreAudioTransport(_ uid: String) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let translated = withUnsafePointer(to: uid as CFString) {
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0,
        &size, &device)
    }
    guard translated == noErr, device != kAudioObjectUnknown else { return nil }
    address.mSelector = kAudioDevicePropertyTransportType
    var transport = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
    return transport
  }
}

/// All sample delivery and conversion run in order on the output's delegate queue.
final class AudioSamples: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let format: AVAudioFormat
  private let audio: @Sendable (AVAudioPCMBuffer) -> Void
  private let firstAudio: @Sendable () -> Void
  private let fail: @Sendable (any Error) -> Void
  private var conversion: Conversion?

  init(
    format: AVAudioFormat, audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (any Error) -> Void
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
      guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
        description.mFormatID == kAudioFormatLinearPCM
      else { throw VoiceError.conversionFailed }
      // Voice treats all channels equally. Keep their byte layout and ignore device-specific speaker labels.
      var stream = description
      let layout =
        stream.mChannelsPerFrame > 2
        ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stream.mChannelsPerFrame)
        : nil
      guard let source = AVAudioFormat(streamDescription: &stream, channelLayout: layout) else {
        throw VoiceError.conversionFailed
      }
      let buffer = try Conversion.allocate(source, frames: AVAudioFrameCount(sampleBuffer.numSamples))
      buffer.frameLength = buffer.frameCapacity
      try sampleBuffer.copyPCMData(
        fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
      if conversion == nil {
        firstAudio()
        conversion = try Conversion(input: buffer.format, output: format)
      }
      if let converted = try conversion?.convert(buffer) { audio(converted) }
    } catch let error as VoiceError {
      fail(error)
    } catch {
      let system = error as NSError
      fail(VoiceSystemError(category: .conversionFailed, domain: system.domain, code: system.code))
    }
  }
}

/// Explicit averaging supports discrete multichannel PCM layouts.
final class Conversion {
  private let source: AVAudioFormat
  private let downmix: (mono: AVAudioFormat, normalizer: AVAudioConverter?)?
  private let converter: AVAudioConverter?

  init(input: AVAudioFormat, output: AVAudioFormat) throws {
    source = input
    if input.channelCount > 1 {
      guard let mono = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 1) else {
        throw VoiceError.conversionFailed
      }
      downmix = (mono, try Self.makeNormalizer(for: input))
    } else {
      downmix = nil
    }
    let effectiveInput = downmix?.mono ?? input
    converter = effectiveInput == output ? nil : try Self.makeConverter(from: effectiveInput, to: output)
  }

  private static func makeNormalizer(for input: AVAudioFormat) throws -> AVAudioConverter? {
    guard input.commonFormat != .pcmFormatFloat32 else { return nil }
    let floats =
      if let layout = input.channelLayout {
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, interleaved: false,
          channelLayout: layout)
      } else {
        AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: input.channelCount)
      }
    guard let floats else { throw VoiceError.conversionFailed }
    return try makeConverter(from: input, to: floats)
  }

  private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws
    -> AVAudioConverter
  {
    guard let converter = AVAudioConverter(from: input, to: output) else {
      throw VoiceError.conversionFailed
    }
    return converter
  }

  fileprivate static func allocate(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws
    -> AVAudioPCMBuffer
  {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw VoiceError.conversionFailed
    }
    return buffer
  }

  func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    guard buffer.format == source else { throw VoiceError.conversionFailed }
    guard buffer.frameLength > 0 else { return nil }
    var input = buffer
    if let downmix {
      if let normalizer = downmix.normalizer {
        input = try Self.convertSameRate(buffer, using: normalizer)
      }
      input = try Self.mix(input, to: downmix.mono)
    }
    guard let converter else { return input }
    let format = converter.outputFormat
    let ratio = format.sampleRate / input.format.sampleRate
    if ratio == 1 { return try Self.convertSameRate(input, using: converter) }
    // Leave room for rate-conversion rounding so the converter can drain the current input.
    let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
    let output = try Self.allocate(format, frames: capacity)
    var error: NSError?
    let status = converter.convert(to: output, error: &error, withInputFrom: Self.inputBlock(input))
    if status == .error {
      if let error { throw error }
      throw VoiceError.conversionFailed
    }
    return output.frameLength > 0 ? output : nil
  }

  private static func convertSameRate(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) throws
    -> AVAudioPCMBuffer
  {
    let output = try allocate(converter.outputFormat, frames: input.frameLength)
    try converter.convert(to: output, from: input)
    return output
  }

  private static func mix(_ input: AVAudioPCMBuffer, to mono: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let mixed = try allocate(mono, frames: input.frameLength)
    guard let channels = input.floatChannelData, let samples = mixed.floatChannelData?[0] else {
      throw VoiceError.conversionFailed
    }
    mixed.frameLength = input.frameLength
    let count = Int(input.format.channelCount)
    let interleaved = input.format.isInterleaved
    for frame in 0..<Int(input.frameLength) {
      var sum: Float = 0
      for channel in 0..<count {
        sum += interleaved ? channels[0][frame * count + channel] : channels[channel][frame]
      }
      samples[frame] = sum / Float(count)
    }
    return mixed
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
