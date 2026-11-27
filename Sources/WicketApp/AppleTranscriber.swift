import AVFoundation
import CoreAudio
import CoreMedia
import IOKit
import Speech
import Synchronization

/// Apple's macOS 26 on-device pipeline. No fallback recognizer, model download or audio file.
@MainActor final class AppleTranscriber: Transcriber {
  private var task: Task<Void, Never>?
  private var microphone: Microphone?
  private(set) var shutdown: AsyncStream<Never>?
  func start(allowBluetooth: Bool, attempt: Int) -> AsyncThrowingStream<VoiceUpdate, any Error> {
    stop()
    let capture = Microphone(attempt: attempt)
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
      // An audio error can finish from the delegate queue; run teardown away from that callback.
      continuation.onTermination = { _ in Task.detached { worker.cancel() } }
    }
  }
  @discardableResult func stop() -> VoiceCapture {
    let capture = microphone
    if let capture { shutdown = capture.stop() }
    microphone = nil
    task?.cancel()
    task = nil
    return capture?.captured ?? .init()
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
      yield(.openingMicrophone(.now))
      try await analyzer.start(inputSequence: inputs)
      try Task.checkCancellation()
      try await microphone.start(
        allowBluetooth: allowBluetooth, format: format, audio: { feed.yield(AnalyzerInput(buffer: $0)) },
        firstAudio: { yield(.audio(.now)) }, fail: fail)
      try Task.checkCancellation()
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
  private let attempt: Int
  private let queue = DispatchQueue(label: "app.wicket.capture", qos: .userInitiated)
  private var session: (any CaptureSession)?
  private let samples = Mutex<AudioSamples?>(nil)
  private var observers: [any NSObjectProtocol] = []
  private let stopped = Atomic(false)

  init(openSlot: DispatchSemaphore = Microphone.hardwareOpen, attempt: Int = 0) {
    self.openSlot = openSlot
    self.attempt = attempt
  }

  private var isStopped: Bool { stopped.load(ordering: .relaxed) }
  var captured: VoiceCapture { samples.withLock { $0?.captured ?? .init() } }

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
    let opened = ContinuousClock.now
    let select = { @Sendable [attempt] in
      try InputDevice.select(allowBluetooth: allowBluetooth, attempt: attempt)
    }
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
      let samples = AudioSamples(
        format: format, deviceName: device.localizedName, attempt: attempt, opened: opened,
        audio: audio, firstAudio: firstAudio, fail: fail)
      // Session startup and teardown can wait for delivery to drain.
      output.setSampleBufferDelegate(
        samples, queue: DispatchQueue(label: "app.wicket.audio", qos: .userInitiated))
      self.samples.withLock { $0 = samples }
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
  struct Description: Equatable, Sendable {
    let transport: UInt32
    let isInternalMicrophone: Bool
    let usesBluetooth: Bool
    let usesContinuity: Bool

    init(
      transport: UInt32, isInternalMicrophone: Bool? = nil, isContinuityCamera: Bool = false,
      inputMembers: [Description] = []
    ) {
      self.transport = transport
      self.isInternalMicrophone =
        isInternalMicrophone
        ?? (transport == kAudioDeviceTransportTypeBuiltIn
          || (!inputMembers.isEmpty && inputMembers.allSatisfy(\.isInternalMicrophone)))
      usesBluetooth =
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        || inputMembers.contains(where: \.usesBluetooth)
      usesContinuity =
        isContinuityCamera || transport == kAudioDeviceTransportTypeContinuityCaptureWired
        || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
        || inputMembers.contains(where: \.usesContinuity)
    }
  }

  static func select(allowBluetooth: Bool, attempt: Int) throws -> AVCaptureDevice {
    try select(
      current: AVCaptureDevice.default(for: .audio), allowBluetooth: allowBluetooth,
      clamshellClosed: isClamshellClosed(),
      discover: { AVCaptureDevice.DiscoverySession(deviceTypes: $0, mediaType: $1, position: $2).devices },
      describe: describe, attempt: attempt
    ).device
  }

  private static func transportName(_ transport: UInt32?) -> String {
    guard let transport else { return "none" }
    return withUnsafeBytes(of: transport.bigEndian) { bytes in
      bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : "unknown"
    }
  }

  private static func isClamshellClosed() -> Bool {
    let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard rootDomain != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(rootDomain) }
    let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, nil, 0)
    return (state?.takeRetainedValue() as? Bool) == true
  }

  static func select<Device>(
    current: Device?, allowBluetooth: Bool, clamshellClosed: Bool = false,
    discover: ([AVCaptureDevice.DeviceType], AVMediaType, AVCaptureDevice.Position) -> [Device],
    describe: (Device) -> Description, attempt: Int? = nil
  ) throws -> (device: Device, transport: UInt32) {
    let currentInfo = current.map(describe)
    var selection: (transport: UInt32, reason: String)?
    defer {
      if let attempt {
        VoiceLog.logger.log(
          "voice \(attempt, privacy: .public) input: lid closed \(clamshellClosed, privacy: .public), default \(transportName(currentInfo?.transport), privacy: .public), selected \(transportName(selection?.transport), privacy: .public), substitution \(selection?.reason ?? "none", privacy: .public)"
        )
      }
    }
    func use(_ device: Device, _ info: Description, reason: String = "none") -> (Device, UInt32) {
      selection = (info.transport, reason)
      return (device, info.transport)
    }
    guard let current, let currentInfo else { throw VoiceError.noMicrophone }
    // macOS can still report the internal mic after the lid disconnects it in hardware.
    let mutedByLid = clamshellClosed && currentInfo.isInternalMicrophone
    // Clicking the mic lets the user pick an input in Sound settings even when other devices are listed.
    if allowBluetooth && !mutedByLid { return use(current, currentInfo) }
    // An aggregate or unidentified default may route a Bluetooth mic, so a verified mic wins over it.
    let unverified =
      !currentInfo.usesContinuity
      && (isAggregateTransport(currentInfo.transport)
        || currentInfo.transport == kAudioDeviceTransportTypeUnknown)
    guard currentInfo.usesBluetooth || unverified || mutedByLid else {
      return use(current, currentInfo)
    }
    let candidates = discover([.microphone, .external], .audio, .unspecified)
      .map { (device: $0, info: describe($0)) }
      .filter { !$0.info.usesContinuity && (!clamshellClosed || !$0.info.isInternalMicrophone) }
    if let replacement = candidates.first(where: { $0.info.transport == kAudioDeviceTransportTypeBuiltIn })
      ?? candidates.first(where: { $0.info.transport == kAudioDeviceTransportTypeUSB })
      ?? candidates.first(where: { !$0.info.usesBluetooth && isNonBluetoothHardware($0.info.transport) })
    {
      let reason = mutedByLid ? "lid" : currentInfo.usesBluetooth ? "bluetooth" : "unverified"
      return use(replacement.device, replacement.info, reason: reason)
    }
    if mutedByLid {
      guard let headset = candidates.first(where: { $0.info.usesBluetooth }) else {
        throw VoiceError.lidClosed
      }
      guard allowBluetooth else { throw VoiceError.bluetoothOnly }
      return use(headset.device, headset.info, reason: "lid")
    }
    guard !currentInfo.usesBluetooth else { throw VoiceError.bluetoothOnly }
    return use(current, currentInfo)
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

  static func transport(coreAudio: UInt32?, captureTransport: UInt32) -> UInt32 {
    guard let coreAudio, coreAudio != kAudioDeviceTransportTypeUnknown else {
      return captureTransport
    }
    return coreAudio
  }

  private static func describe(_ captureDevice: AVCaptureDevice) -> Description {
    let device = coreAudioDevice(for: captureDevice.uniqueID)
    let resolved = transport(
      coreAudio: device.flatMap(coreAudioTransport),
      captureTransport: UInt32(bitPattern: captureDevice.transportType))
    let members = isAggregateTransport(resolved) ? device.map(aggregateInputMembers) ?? [] : []
    return Description(
      transport: resolved,
      isInternalMicrophone: resolved == kAudioDeviceTransportTypeBuiltIn
        ? device.map(isInternalMicrophone) : nil,
      isContinuityCamera: captureDevice.isContinuityCamera, inputMembers: members)
  }

  private static func isAggregateTransport(_ transport: UInt32) -> Bool {
    transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate
  }

  private static func coreAudioDevice(for uid: String) -> AudioDeviceID? {
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
    return device
  }

  private static func coreAudioTransport(_ device: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
    return transport
  }

  /// A 3.5 mm wired headset also reports `BuiltIn`; distinguish it from the lid-muted internal mic.
  private static func isInternalMicrophone(_ device: AudioDeviceID) -> Bool {
    var sourceAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var source = UInt32(0)
    var sourceSize = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &sourceSize, &source) == noErr {
      return source == 0x696D_6963  // 'imic'
    }
    var jackAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyJackIsConnected, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var connected = UInt32(0)
    var jackSize = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(device, &jackAddress, 0, nil, &jackSize, &connected) == noErr,
      connected != 0
    {
      return false
    }
    return true
  }

  private static func aggregateInputMembers(_ device: AudioDeviceID) -> [Description] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var members = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &members) == noErr else { return [] }
    return members.filter(hasInputStream).map { member in
      let transport = coreAudioTransport(member) ?? kAudioDeviceTransportTypeUnknown
      return Description(
        transport: transport,
        isInternalMicrophone: transport == kAudioDeviceTransportTypeBuiltIn && isInternalMicrophone(member))
    }
  }

  private static func hasInputStream(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
  }
}

/// Delivery and conversion stay on the delegate queue. Only the capture summary crosses queues.
final class AudioSamples: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let format: AVAudioFormat
  private let attempt: Int
  private let opened: ContinuousClock.Instant
  private let audio: @Sendable (AVAudioPCMBuffer) -> Void
  private var firstAudio: (@Sendable () -> Void)?
  private let fail: @Sendable (any Error) -> Void
  private let summary: Mutex<VoiceCapture>
  private var conversion: Conversion?
  private var failed = false

  init(
    format: AVAudioFormat, deviceName: String, attempt: Int = 0, opened: ContinuousClock.Instant = .now,
    audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    firstAudio: @escaping @Sendable () -> Void, fail: @escaping @Sendable (any Error) -> Void
  ) {
    self.format = format
    self.attempt = attempt
    self.opened = opened
    self.audio = audio
    self.firstAudio = firstAudio
    self.fail = fail
    summary = Mutex(.init(silentDevice: deviceName))
  }

  var captured: VoiceCapture { summary.withLock { $0 } }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    receive(sampleBuffer)
  }

  func receive(_ sampleBuffer: CMSampleBuffer) {
    let (index, checkSignal) = summary.withLock {
      $0.buffers += 1
      return ($0.buffers, $0.silentDevice != nil)
    }
    let description = sampleBuffer.formatDescription?.audioStreamBasicDescription
    if index == 1 {
      VoiceLog.logger.log(
        "voice \(self.attempt, privacy: .public) first buffer: \(Self.describe(description), privacy: .public), \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after open"
      )
    }
    guard !failed, sampleBuffer.numSamples > 0 else { return }
    var stage = Conversion.Stage.copy
    do {
      guard var stream = description else { throw Conversion.Stage.nonPCM }
      guard stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else { return }
      guard stream.mFormatID == kAudioFormatLinearPCM else { throw Conversion.Stage.nonPCM }
      // Channel order is all that matters for averaging discrete multichannel PCM.
      let layout =
        stream.mChannelsPerFrame > 2
        ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stream.mChannelsPerFrame)
        : nil
      guard let source = AVAudioFormat(streamDescription: &stream, channelLayout: layout) else {
        throw Conversion.Stage.format
      }
      let buffer = try Conversion.allocate(source, frames: AVAudioFrameCount(sampleBuffer.numSamples))
      buffer.frameLength = buffer.frameCapacity
      try sampleBuffer.copyPCMData(
        fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
      if checkSignal, Self.hasSignal(buffer) {
        summary.withLock { $0.silentDevice = nil }
      }
      // At startup the capture session can deliver the physical integer format before correcting to Float32.
      if conversion?.source != source {
        if conversion != nil {
          summary.withLock { $0.formatChanges += 1 }
          VoiceLog.logger.log(
            "voice \(self.attempt, privacy: .public) format changed at buffer \(index, privacy: .public): \(Self.describe(stream), privacy: .public)"
          )
        }
        conversion = try Conversion(input: source, output: format)
      }
      stage = .convert
      try conversion?.convert(buffer) { converted in
        audio(converted)
        firstAudio?()
        firstAudio = nil
      }
    } catch {
      failed = true
      let failure = (error as? Conversion.Stage) ?? stage
      VoiceLog.logger.error(
        "voice \(self.attempt, privacy: .public) conversion failed at \(failure.rawValue, privacy: .public), buffer \(index, privacy: .public): \(Self.describe(description), privacy: .public)"
      )
      if error is Conversion.Stage {
        fail(VoiceError.conversionFailed)
      } else {
        let system = error as NSError
        fail(VoiceSystemError(category: .conversionFailed, domain: system.domain, code: system.code))
      }
    }
  }

  private static func describe(_ stream: AudioStreamBasicDescription?) -> String {
    guard let stream else { return "no format" }
    let flags = stream.mFormatFlags
    let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
    return
      "\(stream.mSampleRate) Hz, \(stream.mChannelsPerFrame) ch, \(stream.mBitsPerChannel) bit, flags \(flags), interleaved \(interleaved)"
  }

  private static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
    UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).contains { channel in
      let bytes = UnsafeRawBufferPointer(start: channel.mData, count: Int(channel.mDataByteSize))
      // Signed zero is also silence in floating-point PCM.
      return switch buffer.format.commonFormat {
      case .pcmFormatFloat32: bytes.bindMemory(to: Float.self).contains { $0 != 0 }
      case .pcmFormatFloat64: bytes.bindMemory(to: Double.self).contains { $0 != 0 }
      default: bytes.contains { $0 != 0 }
      }
    }
  }
}

/// Explicit averaging supports discrete multichannel PCM layouts.
final class Conversion {
  enum Stage: String, Error { case nonPCM, format, alloc, copy, converter, convert }

  let source: AVAudioFormat
  private let downmix: (mono: AVAudioFormat, normalizer: AVAudioConverter?)?
  private let converter: AVAudioConverter?

  init(input: AVAudioFormat, output: AVAudioFormat) throws {
    source = input
    if input.channelCount > 2 {
      guard let mono = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 1) else {
        throw Stage.format
      }
      downmix = (mono, try Self.makeNormalizer(for: input))
    } else {
      downmix = nil
    }
    let effectiveInput = downmix?.mono ?? input
    converter = effectiveInput == output ? nil : try Self.makeConverter(from: effectiveInput, to: output)
    converter?.downmix = true
  }

  private static func makeNormalizer(for input: AVAudioFormat) throws -> AVAudioConverter? {
    guard input.commonFormat != .pcmFormatFloat32 else { return nil }
    guard
      let layout = input.channelLayout
        ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | input.channelCount)
    else { throw Stage.format }
    let floats = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, interleaved: false, channelLayout: layout
    )
    return try makeConverter(from: input, to: floats)
  }

  private static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws
    -> AVAudioConverter
  {
    guard let converter = AVAudioConverter(from: input, to: output) else { throw Stage.converter }
    return converter
  }

  fileprivate static func allocate(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws
    -> AVAudioPCMBuffer
  {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw Stage.alloc }
    return buffer
  }

  func convert(_ buffer: AVAudioPCMBuffer, deliver: (AVAudioPCMBuffer) -> Void) throws {
    guard buffer.format == source else { throw Stage.format }
    guard buffer.frameLength > 0 else { return }
    var input = buffer
    if let downmix {
      if let normalizer = downmix.normalizer {
        input = try Self.allocate(normalizer.outputFormat, frames: buffer.frameLength)
        try normalizer.convert(to: input, from: buffer)
      }
      input = try Self.mix(input, to: downmix.mono)
    }
    guard let converter else { return deliver(input) }
    let format = converter.outputFormat
    let ratio = format.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
    // The converter calls the input block synchronously. Offer the packet once across all drains.
    nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
    var status: AVAudioConverterOutputStatus
    repeat {
      let output = try Self.allocate(format, frames: capacity)
      var error: NSError?
      status = converter.convert(to: output, error: &error) { _, status in
        let packet = pending
        pending = nil
        status.pointee = packet == nil ? .noDataNow : .haveData
        return packet
      }
      if status == .error { throw (error as (any Error)?) ?? Stage.convert }
      if output.frameLength > 0 { deliver(output) }
    } while status == .haveData
  }

  private static func mix(_ input: AVAudioPCMBuffer, to mono: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let mixed = try allocate(mono, frames: input.frameLength)
    guard let channels = input.floatChannelData, let samples = mixed.floatChannelData?[0] else {
      throw Stage.format
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
