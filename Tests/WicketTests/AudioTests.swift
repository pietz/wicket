import AVFoundation
import CoreAudio
import CoreMedia
import Synchronization
import Testing

@testable import WicketApp

private func audio(_ channels: UInt32, rate: Double = 48000, interleaved: Bool = false) throws
  -> AVAudioPCMBuffer
{
  let tag =
    switch channels {
    case 1: kAudioChannelLayoutTag_Mono
    case 2: kAudioChannelLayoutTag_Stereo
    default: kAudioChannelLayoutTag_DiscreteInOrder | channels
    }
  let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
  let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
  buffer.frameLength = 4800
  for channel in 0..<Int(channels) {
    for frame in 0..<4800 {
      buffer.floatChannelData![interleaved ? 0 : channel][
        interleaved ? frame * Int(channels) + channel : frame] = Float(channel + 1) / Float(channels)
    }
  }
  return buffer
}

@Test(arguments: [1, 2, 4, 6], [false, true])
func synthesizedAudioPreservesRateAndChannelAverage(_ channels: UInt32, _ interleaved: Bool) throws {
  let input = try audio(channels, interleaved: interleaved)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let conversion = try Conversion(input: input.format, output: output)
  let expected = Float(channels + 1) / (2 * Float(channels))
  var frames: AVAudioFrameCount = 0
  try conversion.convert(input) { result in
    #expect(result.frameLength > 500 && abs(result.floatChannelData![0][500] - expected) < 0.001)
    frames += result.frameLength
  }
  #expect((1001...1600).contains(frames))
}

/// Counts what opening and closing do in place of hardware.
private final class FakeCapture: CaptureSession, @unchecked Sendable {
  let counts = Mutex((starts: 0, stops: 0, detaches: 0))
  let isRunning: Bool
  private let onStart: @Sendable () -> Void

  init(running: Bool = true, onStart: @escaping @Sendable () -> Void = {}) {
    isRunning = running
    self.onStart = onStart
  }
  func startRunning() {
    counts.withLock { $0.starts += 1 }
    onStart()
  }
  func stopRunning() { counts.withLock { $0.stops += 1 } }
  func detach() {
    counts.withLock {
      #expect($0.starts == $0.stops)
      $0.detaches += 1
    }
  }
}

@Test func microphoneStoppedBeforeOpeningNeverOpens() async {
  // The close is already queued, even when the caller hasn't waited for it.
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  let shutdown = microphone.stop()
  await #expect(throws: CancellationError.self) {
    try await microphone.open(
      selecting: {},
      session: { _ in
        Issue.record("Opened after stop")
        return FakeCapture()
      })
  }
  for await _ in shutdown {}
}

@Test func microphoneClosesExactlyOnceAfterLosingItsInput() async throws {
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  let capture = FakeCapture()
  try await microphone.open(selecting: {}, session: { _ in capture })
  await #expect(throws: CancellationError.self) {
    try await microphone.open(
      selecting: {},
      session: { _ in
        Issue.record("Reopened")
        return FakeCapture()
      })
  }
  let retries = Mutex(0)
  let lostInput = DispatchSemaphore(value: 0)
  for _ in 0..<2 {
    microphone.captureEnded {
      #expect($0 as? VoiceError == .inputChanged)
      retries.withLock { $0 += 1 }
      lostInput.signal()
    }
  }
  #expect(await signalArrives(lostInput, within: 60))
  for await _ in microphone.stop() {}
  for await _ in microphone.stop() {}
  #expect(capture.counts.withLock { $0 } == (1, 1, 1))
  #expect(retries.withLock { $0 } == 1)
}

@Test func microphoneThatFailsToRunClosesAndReportsStartupFailure() async {
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  let capture = FakeCapture(running: false)
  await #expect(throws: VoiceError.microphoneStartFailed) {
    try await microphone.open(selecting: {}, session: { _ in capture })
  }
  #expect(capture.counts.withLock { $0 } == (1, 1, 1))
}

@Test func detachingCaptureClearsTheSampleDelegateAndRemovesTheOutput() throws {
  let capture = AVCaptureSession()
  let output = AVCaptureAudioDataOutput()
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let samples = AudioSamples(
    format: format, deviceName: "Test input", audio: { _ in }, firstAudio: {}, fail: { _ in })
  try #require(capture.canAddOutput(output))
  capture.addOutput(output)
  output.setSampleBufferDelegate(samples, queue: DispatchQueue(label: "test.audio"))
  #expect(output.sampleBufferDelegate === samples)
  capture.detach()
  #expect(output.sampleBufferDelegate == nil && capture.outputs.isEmpty)
}

private enum CaptureStep: CaseIterable, Sendable { case selection, construction, startup }

@MainActor @Test(arguments: CaptureStep.allCases)
private func stalledMicrophoneOpenCanBeCancelledAndDoesNotPileUp(_ step: CaptureStep) async throws {
  let openSlot = DispatchSemaphore(value: 1)
  let microphone = Microphone(openSlot: openSlot)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  // Block until the test releases the fake. The wait limits are harness watchdogs.
  let stall: @Sendable () -> Void = {
    entered.signal()
    if release.wait(timeout: .now() + 60) == .timedOut {
      Issue.record("Harness timeout: the opening was never released")
    }
  }
  let capture = FakeCapture { if step == .startup { stall() } }
  var stoppedWaiting = false
  let opening = Task {
    defer { stoppedWaiting = true }
    try await microphone.open(
      selecting: {
        if step == .selection { stall() }
      },
      session: { _ in
        #expect(step != .selection, "Constructed a session after cancellation")
        if step == .construction { stall() }
        return capture
      })
  }
  #expect(await signalArrives(entered, within: 60), "Harness timeout: the opening never started")
  let shutdown = microphone.stop()
  var closed = false
  let watcher = Task {
    for await _ in shutdown {}
    closed = true
  }
  opening.cancel()
  #expect(await eventually(within: .seconds(15)) { stoppedWaiting })
  #expect(!closed)

  let retry = Microphone(openSlot: openSlot)
  await #expect(throws: VoiceError.microphoneStartFailed) {
    try await retry.open(
      selecting: { Issue.record("Retried discovery while the driver was blocked") },
      session: { _ in FakeCapture() })
  }
  release.signal()
  await watcher.value
  await #expect(throws: CancellationError.self) { try await opening.value }
  let expected =
    switch step {
    case .selection: (0, 0, 0)
    case .construction: (0, 0, 1)
    case .startup: (1, 1, 1)
    }
  #expect(capture.counts.withLock { $0 } == expected)

  let fresh = FakeCapture()
  try await retry.open(selecting: {}, session: { _ in fresh })
  for await _ in retry.stop() {}
  #expect(fresh.counts.withLock { $0 } == (1, 1, 1))
}

private func signalArrives(_ signal: DispatchSemaphore, within seconds: Double) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: signal.wait(timeout: .now() + seconds) == .success)
    }
  }
}

@Test func conversionDownmixesInterleavedInputAndReportsFormatFailures() throws {
  let input = try audio(4, interleaved: true)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
  let conversion = try Conversion(input: input.format, output: output)
  try conversion.convert(input) {
    #expect($0.frameLength > 500 && abs($0.floatChannelData![0][500] - 0.625) < 0.001)
  }
  var frames: AVAudioFrameCount = 0
  for length: AVAudioFrameCount in [49, 4799, 3, 128, 4800] {
    input.frameLength = length
    try conversion.convert(input) { frames += $0.frameLength }
  }
  #expect((8983...8986).contains(frames))
  let wrong = try audio(1)
  #expect(throws: Conversion.Stage.format) { try conversion.convert(wrong) { _ in } }
}

private func captureSample(_ input: AVAudioPCMBuffer) throws -> CMSampleBuffer {
  var sample: CMSampleBuffer?
  let created = CMAudioSampleBufferCreateWithPacketDescriptions(
    allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
    refcon: nil, formatDescription: input.format.formatDescription, sampleCount: Int(input.frameLength),
    presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
  try #require(created == noErr)
  let sampleBuffer = try #require(sample)
  let copied = CMSampleBufferSetDataBufferFromAudioBufferList(
    sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
    flags: 0, bufferList: input.audioBufferList)
  try #require(copied == noErr)
  try #require(CMSampleBufferSetDataReady(sampleBuffer) == noErr)
  return sampleBuffer
}

@Test func thirtyTwoKilohertzStereoReachesTheAnalyzerFormat() throws {
  let input = try audio(2, rate: 32000)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let sampleBuffer = try captureSample(input)
  let counts = Mutex((audio: 0, first: 0))
  let receiver = AudioSamples(
    format: output, deviceName: "Test input",
    audio: { result in
      #expect(result.format == output && (2001...2401).contains(result.frameLength))
      #expect(abs(result.floatChannelData![0][500] - 0.75) < 0.001)
      counts.withLock { $0.audio += 1 }
    },
    firstAudio: { counts.withLock { $0.first += 1 } },
    fail: { Issue.record("Audio failed: \($0)") })
  receiver.receive(sampleBuffer)
  receiver.receive(sampleBuffer)
  #expect(counts.withLock { $0 } == (2, 1))
}

@Test func inputFormatChangeMidSessionKeepsDeliveringAudio() throws {
  let output = try #require(
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
  let integer = try #require(
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 32000, channels: 2, interleaved: true))
  let input = try #require(AVAudioPCMBuffer(pcmFormat: integer, frameCapacity: 4800))
  input.frameLength = 4800
  let stereo = try #require(input.int16ChannelData?[0])
  for frame in 0..<4800 {
    stereo[2 * frame] = 0
    stereo[2 * frame + 1] = 16000
  }
  let before = try captureSample(input)
  let after = try captureSample(try audio(2, rate: 32000))
  let samples = Mutex([Int16]())
  let first = Mutex(0)
  let receiver = AudioSamples(
    format: output, deviceName: "Test input",
    audio: { result in
      #expect(result.format == output)
      let data = result.int16ChannelData![0]
      samples.withLock { $0.append(contentsOf: (0..<Int(result.frameLength)).map { data[$0] }) }
    },
    firstAudio: { first.withLock { $0 += 1 } },
    fail: { Issue.record("Audio failed: \(VoiceLog.describe($0))") })
  for packet in [before, after, after] { receiver.receive(packet) }
  // All 2,400 output frames of the integer buffer arrive, including the tail the resampler held back.
  let values = samples.withLock { $0 }
  #expect(values.count(where: { abs(Int($0) - 8000) <= 1 }) >= 2380)
  #expect(values.count(where: { abs(Int($0) - 24576) <= 1 }) > 4000)
  #expect(first.withLock { $0 } == 1)
  #expect(receiver.captured.buffers == 3 && receiver.captured.formatChanges == 1)
}

@Test(arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16])
func digitalSilenceKeepsDeliveringUntilSignalArrives(_ analyzerFormat: AVAudioCommonFormat) throws {
  let input = try audio(2, interleaved: true)
  let output = try #require(
    AVAudioFormat(commonFormat: analyzerFormat, sampleRate: 16000, channels: 1, interleaved: false))
  input.floatChannelData![0].update(repeating: -0.0, count: 2 * Int(input.frameLength))
  let packet = try captureSample(input)
  let delivered = Mutex(0)
  let receiver = AudioSamples(
    format: output, deviceName: "Dock",
    audio: { _ in delivered.withLock { $0 += 1 } }, firstAudio: {},
    fail: { Issue.record("Audio failed: \(VoiceLog.describe($0))") })
  for _ in 0..<20 { receiver.receive(packet) }
  #expect(delivered.withLock { $0 } == 20)
  #expect(receiver.captured.silentDevice == "Dock")
  input.floatChannelData![0][0] = 0.001  // A quiet room's noise floor, well above one 16-bit step.
  receiver.receive(try captureSample(input))
  receiver.receive(packet)
  #expect(delivered.withLock { $0 } == 22)
  #expect(receiver.captured.silentDevice == nil)
}

@Test(
  arguments: [false, true],
  [
    kAudioChannelLayoutTag_Mono, kAudioChannelLayoutTag_DiscreteInOrder | 1,
    kAudioChannelLayoutTag_Unknown | 1,
  ])
func sixteenKilohertzMonoPreservesSamples(_ interleaved: Bool, _ tag: AudioChannelLayoutTag) throws {
  let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
  let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, interleaved: interleaved, channelLayout: layout)
  let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
  input.frameLength = 320
  let data = try #require(input.int16ChannelData?[0])
  // Distinct packets expose dropped or repeated samples across the conversion calls.
  let values: [Int16] = [-16384, 8192]
  let packets = try values.map { value in
    for frame in 0..<Int(input.frameLength) { data[frame] = value }
    return try captureSample(input)
  }
  for outputFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
    let output = try #require(
      AVAudioFormat(commonFormat: outputFormat, sampleRate: 16000, channels: 1, interleaved: false))
    let received = Mutex([Float]())
    let first = Mutex(0)
    let receiver = AudioSamples(
      format: output, deviceName: "Test input",
      audio: { buffer in
        #expect(buffer.format == output)
        #expect(buffer.frameLength == 320)
        let samples = (0..<Int(buffer.frameLength)).map { frame in
          if let floats = buffer.floatChannelData { return floats[0][frame] }
          return Float(buffer.int16ChannelData![0][frame]) / 32768
        }
        received.withLock { $0.append(contentsOf: samples) }
      },
      firstAudio: { first.withLock { $0 += 1 } },
      fail: { Issue.record("Audio failed: \(VoiceLog.describe($0))") })
    for packet in packets { receiver.receive(packet) }
    let expected = values.flatMap { Array(repeating: Float($0) / 32768, count: 320) }
    #expect(received.withLock { $0 } == expected)
    #expect(first.withLock { $0 } == 1)
  }
}

@Test func packedIntegerChannelsAreAveragedBySampleOrder() throws {
  // USB microphones can supply packed 24-bit PCM outside AVAudioCommonFormat.
  let count: UInt32 = 4
  var asbd = AudioStreamBasicDescription(
    mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: count * 3, mFramesPerPacket: 1, mBytesPerFrame: count * 3,
    mChannelsPerFrame: count, mBitsPerChannel: 24, mReserved: 0)
  let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
  let format = try #require(AVAudioFormat(streamDescription: &asbd, channelLayout: layout))
  #expect(format.commonFormat == .otherFormat)
  let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
  input.frameLength = 320
  let bytes = try #require(input.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: UInt8.self)
  let frame: [UInt8] = [0, 0, 0x40, 0, 0, 0x20, 0, 0, 0, 0, 0, 0xE0]
  for index in 0..<Int(input.frameLength) {
    frame.withUnsafeBufferPointer {
      bytes.advanced(by: index * frame.count).update(from: $0.baseAddress!, count: frame.count)
    }
  }
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let received = Mutex(0)
  let receiver = AudioSamples(
    format: output, deviceName: "Test input",
    audio: { buffer in
      #expect(buffer.format == output)
      #expect(buffer.frameLength == 320)
      #expect(buffer.floatChannelData?[0][0] == 0.125)
      #expect(buffer.floatChannelData?[0][319] == 0.125)
      received.withLock { $0 += 1 }
    },
    firstAudio: {},
    fail: { Issue.record("Audio failed: \(VoiceLog.describe($0))") })
  receiver.receive(try captureSample(input))
  #expect(received.withLock { $0 } == 1)
}

@Test func copyingMicrophoneSamplesPreservesTheSystemError() throws {
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  var sample: CMSampleBuffer?
  let created = CMAudioSampleBufferCreateWithPacketDescriptions(
    allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
    refcon: nil, formatDescription: format.formatDescription, sampleCount: 320,
    presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
  try #require(created == noErr)
  let errors = Mutex([VoiceSystemError]())
  let receiver = AudioSamples(
    format: format, deviceName: "Test input",
    audio: { _ in Issue.record("Delivered audio from an unreadable buffer") },
    firstAudio: { Issue.record("Reported first audio from an unreadable buffer") },
    fail: { error in
      guard let system = error as? VoiceSystemError else {
        Issue.record("Missing system error")
        return
      }
      errors.withLock { $0.append(system) }
    })
  receiver.receive(try #require(sample))
  let reported = errors.withLock { $0 }
  #expect(reported.count == 1)
  let error = try #require(reported.first)
  #expect(error.category == .conversionFailed)
  #expect(error.domain == NSOSStatusErrorDomain && error.code == Int(kCMSampleBufferError_BufferNotReady))
  #expect(VoiceLog.describe(error) == "conversionFailed (\(error.domain) \(error.code))")
}

@Test func bluetoothInputIsReplacedBeforeTheCaptureSessionIsMade() async throws {
  let headset = (uid: "headset", transport: kAudioDeviceTransportTypeUnknown)
  let builtin = kAudioDeviceTransportTypeBuiltIn
  let usb = kAudioDeviceTransportTypeUSB
  let virtual = kAudioDeviceTransportTypeVirtual
  let capture = FakeCapture()
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  try await microphone.open(
    selecting: {
      try InputDevice.select(
        current: headset, allowBluetooth: false,
        discover: { _, _, _ in [headset, ("virtual", virtual), ("usb", usb), ("mac", builtin)] },
        transport: { device in
          InputDevice.transport(
            coreAudio: device.uid == headset.uid ? kAudioDeviceTransportTypeBluetooth : nil,
            captureTransport: device.transport)
        })
    },
    session: { selected in
      #expect(selected.device.uid == "mac" && selected.transport == builtin)
      #expect(capture.counts.withLock { $0 } == (0, 0, 0))
      return capture
    })
  for await _ in microphone.stop() {}
  #expect(capture.counts.withLock { $0 } == (1, 1, 1))
}

@Test(arguments: [
  kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
  kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI,
])
func nonBluetoothHardwareReplacesABluetoothDefault(_ hardware: UInt32) throws {
  let bluetoothLE = kAudioDeviceTransportTypeBluetoothLE
  let virtual = kAudioDeviceTransportTypeVirtual
  let fallback = try InputDevice.select(
    current: bluetoothLE, allowBluetooth: false,
    discover: { types, media, position in
      #expect(types == [.microphone, .external] && media == .audio && position == .unspecified)
      return [bluetoothLE, virtual, hardware]
    }, transport: { $0 })
  #expect(fallback.device == hardware)
}

@Test(arguments: [
  kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate,
  kAudioDeviceTransportTypeUnknown,
])
func verifiedMicReplacesAnUnverifiedDefaultWhichStaysUsableAlone(_ unverified: UInt32) throws {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  #expect(
    try InputDevice.select(
      current: unverified, allowBluetooth: false, discover: { _, _, _ in [unverified, builtIn] },
      transport: { $0 }
    ).device == builtIn)
  #expect(
    try InputDevice.select(
      current: unverified, allowBluetooth: false, discover: { _, _, _ in [unverified] }, transport: { $0 }
    ).device == unverified)
}

@Test func nonBluetoothDefaultIsKept() throws {
  for current in [
    kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeVirtual,
  ] {
    #expect(
      try InputDevice.select(
        current: current, allowBluetooth: false,
        discover: { _, _, _ in
          Issue.record("Looked for a replacement for a non-Bluetooth input")
          return []
        }, transport: { $0 }
      ).device == current)
  }
}

@Test(arguments: [false, true])
func closedLidReplacesBuiltInWithExternalHardware(_ usbConnected: Bool) throws {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  let external = kAudioDeviceTransportTypeThunderbolt
  let usb = kAudioDeviceTransportTypeUSB
  let selected = try InputDevice.select(
    current: builtIn, allowBluetooth: false, clamshellClosed: true,
    discover: { types, media, position in
      #expect(types == [.microphone, .external] && media == .audio && position == .unspecified)
      return [builtIn, external] + (usbConnected ? [usb] : [])
    }, transport: { $0 })
  #expect(selected.device == (usbConnected ? usb : external))
}

@Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeAggregate], [false, true])
func replacementPrefersUSBOnlyWhenLidIsClosed(_ current: UInt32, _ clamshellClosed: Bool) throws {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  let usb = kAudioDeviceTransportTypeUSB
  let selected = try InputDevice.select(
    current: current, allowBluetooth: false, clamshellClosed: clamshellClosed,
    discover: { _, _, _ in [current, builtIn, usb] }, transport: { $0 })
  #expect(selected.device == (clamshellClosed ? usb : builtIn))
}

@Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE], [false, true])
func closedLidBluetoothRequiresExplicitStart(_ bluetooth: UInt32, _ builtInIsDefault: Bool) throws {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  let current = builtInIsDefault ? builtIn : bluetooth
  func select(allowBluetooth: Bool) throws -> UInt32 {
    try InputDevice.select(
      current: current, allowBluetooth: allowBluetooth, clamshellClosed: true,
      discover: { _, _, _ in [builtIn, bluetooth] }, transport: { $0 }
    ).device
  }
  #expect(throws: VoiceError.bluetoothOnly) { try select(allowBluetooth: false) }
  #expect(try select(allowBluetooth: true) == bluetooth)
}

@Test(arguments: [false, true])
func closedLidReportsWhenBuiltInHasNoUsableReplacement(_ allowBluetooth: Bool) {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  #expect(throws: VoiceError.lidClosed) {
    try InputDevice.select(
      current: builtIn, allowBluetooth: allowBluetooth, clamshellClosed: true,
      discover: { _, _, _ in [builtIn, kAudioDeviceTransportTypeVirtual] }, transport: { $0 })
  }
}

@Test func closedLidKeepsWiredBuiltInHeadsetAndUsesItToReplaceInternalMic() throws {
  let internalMic = (
    name: "internal",
    info: InputDevice.Description(transport: kAudioDeviceTransportTypeBuiltIn, isInternalMicrophone: true)
  )
  let headset = (
    name: "headset",
    info: InputDevice.Description(transport: kAudioDeviceTransportTypeBuiltIn, isInternalMicrophone: false)
  )
  let kept = try InputDevice.select(
    current: headset, allowBluetooth: false, clamshellClosed: true,
    discover: { _, _, _ in
      Issue.record("Looked for a replacement for a working wired headset")
      return []
    }, describe: \.info)
  #expect(kept.device.name == "headset")

  let replaced = try InputDevice.select(
    current: internalMic, allowBluetooth: false, clamshellClosed: true,
    discover: { _, _, _ in [internalMic, headset] }, describe: \.info)
  #expect(replaced.device.name == "headset")
}

@Test func closedLidBluetoothAggregateRequiresExplicitStart() throws {
  let internalMic = (
    name: "internal",
    info: InputDevice.Description(transport: kAudioDeviceTransportTypeBuiltIn, isInternalMicrophone: true)
  )
  let aggregate = (
    name: "aggregate",
    info: InputDevice.Description(
      transport: kAudioDeviceTransportTypeAggregate,
      inputMembers: [InputDevice.Description(transport: kAudioDeviceTransportTypeBluetooth)])
  )
  func select(allowBluetooth: Bool) throws -> String {
    try InputDevice.select(
      current: aggregate, allowBluetooth: allowBluetooth, clamshellClosed: true,
      discover: { _, _, _ in [internalMic, aggregate] }, describe: \.info
    ).device.name
  }
  #expect(throws: VoiceError.bluetoothOnly) { try select(allowBluetooth: false) }
  #expect(try select(allowBluetooth: true) == "aggregate")
}

@Test(arguments: [kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate])
func closedLidSkipsAnAggregateOnlyWhenAllItsInputsAreInternal(_ transport: UInt32) throws {
  let builtIn = InputDevice.Description(transport: kAudioDeviceTransportTypeBuiltIn)
  let usb = InputDevice.Description(transport: kAudioDeviceTransportTypeUSB)
  for members in [[builtIn], [builtIn, usb], []] {
    let aggregate = InputDevice.Description(transport: transport, inputMembers: members)
    if members == [builtIn] {
      #expect(throws: VoiceError.lidClosed) {
        try InputDevice.select(
          current: aggregate, allowBluetooth: false, clamshellClosed: true,
          discover: { _, _, _ in [builtIn, aggregate] }, describe: { $0 })
      }
    } else {
      #expect(
        try InputDevice.select(
          current: aggregate, allowBluetooth: false, clamshellClosed: true,
          discover: { _, _, _ in [builtIn, aggregate] }, describe: { $0 }
        ).device == aggregate)
    }
  }
}

@Test func explicitStartHonorsBluetoothDefaultOverDockInput() throws {
  let buds = kAudioDeviceTransportTypeBluetooth
  let dock = kAudioDeviceTransportTypeUSB
  for manual in [false, true] {
    #expect(
      try InputDevice.select(
        current: buds, allowBluetooth: manual, clamshellClosed: true,
        discover: { _, _, _ in [dock, buds] }, transport: { $0 }
      ).device == (manual ? buds : dock))
  }
}

@Test(arguments: [
  kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
])
func continuityIsAvailableOnlyAsTheSystemDefault(_ phone: UInt32) throws {
  let builtIn = kAudioDeviceTransportTypeBuiltIn
  let buds = kAudioDeviceTransportTypeBluetooth
  #expect(throws: VoiceError.lidClosed) {
    try InputDevice.select(
      current: builtIn, allowBluetooth: true, clamshellClosed: true,
      discover: { _, _, _ in [builtIn, phone] }, transport: { $0 })
  }
  #expect(throws: VoiceError.bluetoothOnly) {
    try InputDevice.select(
      current: buds, allowBluetooth: false, clamshellClosed: true,
      discover: { _, _, _ in [builtIn, phone, buds] }, transport: { $0 })
  }
  #expect(
    try InputDevice.select(
      current: phone, allowBluetooth: false, clamshellClosed: true,
      discover: { _, _, _ in [builtIn, phone, buds] }, transport: { $0 }
    ).device == phone)
}

@Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
func bluetoothRequiresAnExplicitStart(_ transport: UInt32) async throws {
  let select: @Sendable (Bool) throws -> UInt32 = { allowBluetooth in
    try InputDevice.select(
      current: transport, allowBluetooth: allowBluetooth,
      discover: { _, _, _ in [transport, kAudioDeviceTransportTypeVirtual] },
      transport: { $0 }
    ).device
  }
  let openSlot = DispatchSemaphore(value: 1)
  let automatic = Microphone(openSlot: openSlot)
  await #expect(throws: VoiceError.bluetoothOnly) {
    try await automatic.open(
      selecting: { try select(false) },
      session: { _ in
        Issue.record("Constructed a capture session for automatic Bluetooth input")
        return FakeCapture()
      })
  }
  let manual = Microphone(openSlot: openSlot)
  let capture = FakeCapture()
  try await manual.open(
    selecting: { try select(true) },
    session: { selected in
      #expect(selected == transport)
      return capture
    })
  for await _ in manual.stop() {}
  #expect(capture.counts.withLock { $0 } == (1, 1, 1))
}

extension InputDevice {
  fileprivate static func select<Device>(
    current: Device?, allowBluetooth: Bool, clamshellClosed: Bool = false,
    discover: ([AVCaptureDevice.DeviceType], AVMediaType, AVCaptureDevice.Position) -> [Device],
    transport: (Device) -> UInt32
  ) throws -> (device: Device, transport: UInt32) {
    try select(
      current: current, allowBluetooth: allowBluetooth, clamshellClosed: clamshellClosed,
      discover: discover, describe: { Description(transport: transport($0)) })
  }
}
