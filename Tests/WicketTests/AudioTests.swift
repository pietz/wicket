import AVFoundation
import CoreAudio
import CoreMedia
import Synchronization
import Testing

@testable import WicketApp

private func audio(_ channels: UInt32, rate: Double = 48000, interleaved: Bool = false) throws
  -> AVAudioPCMBuffer
{
  var asbd = AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
    mBytesPerPacket: interleaved ? channels * 4 : 4, mFramesPerPacket: 1,
    mBytesPerFrame: interleaved ? channels * 4 : 4, mChannelsPerFrame: channels, mBitsPerChannel: 32,
    mReserved: 0)
  let layout = try #require(
    AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
  let format = try #require(AVAudioFormat(streamDescription: &asbd, channelLayout: layout))
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
  let result = try #require(try conversion.convert(input))
  #expect(result.frameCapacity == 1601 && result.frameLength > 1000 && result.frameLength <= 1600)
  let expected = Float(channels + 1) / (2 * Float(channels))
  #expect(abs(result.floatChannelData![0][500] - expected) < 0.001)
}

/// Counts what opening and closing do in place of hardware.
private final class FakeCapture: CaptureSession, @unchecked Sendable {
  let counts = Mutex((starts: 0, stops: 0))
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
  #expect(capture.counts.withLock { $0 } == (1, 1))
  #expect(retries.withLock { $0 } == 1)
}

@Test func microphoneThatFailsToRunClosesAndReportsStartupFailure() async {
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  let capture = FakeCapture(running: false)
  await #expect(throws: VoiceError.microphoneStartFailed) {
    try await microphone.open(selecting: {}, session: { _ in capture })
  }
  #expect(capture.counts.withLock { $0 } == (1, 1))
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
  #expect(capture.counts.withLock { $0 } == (step == .startup ? (1, 1) : (0, 0)))

  let fresh = FakeCapture()
  try await retry.open(selecting: {}, session: { _ in fresh })
  for await _ in retry.stop() {}
  #expect(fresh.counts.withLock { $0 } == (1, 1))
}

private func signalArrives(_ signal: DispatchSemaphore, within seconds: Double) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: signal.wait(timeout: .now() + seconds) == .success)
    }
  }
}

@Test func conversionSuppliesEachBufferOnceThenNoDataNow() throws {
  let input = try audio(1)
  let block = Conversion.inputBlock(input)
  var state = AVAudioConverterInputStatus.noDataNow
  #expect(block(4800, &state) === input && state == .haveData)
  #expect(block(4800, &state) == nil && state == .noDataNow)
  #expect(block(4800, &state) == nil && state == .noDataNow)
}

@Test func conversionDownmixesInterleavedInputAndReportsFormatFailures() throws {
  let input = try audio(4, interleaved: true)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
  let conversion = try Conversion(input: input.format, output: output)
  let converted = try #require(try conversion.convert(input))
  #expect((4411...4412).contains(converted.frameCapacity))
  #expect(converted.frameLength > 0)  // The first buffer pays the converter's filter priming delay.
  let steady = try #require(try conversion.convert(input))
  #expect((4410...4412).contains(steady.frameLength))
  #expect(abs(converted.floatChannelData![0][500] - 0.625) < 0.001)
  let wrong = try audio(1)
  #expect(throws: VoiceError.conversionFailed) { try conversion.convert(wrong) }
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
    format: output,
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
      format: output,
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
    format: output,
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
    format: format,
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
  let bluetooth = kAudioDeviceTransportTypeBluetooth
  let bluetoothLE = kAudioDeviceTransportTypeBluetoothLE
  let builtin = kAudioDeviceTransportTypeBuiltIn
  let usb = kAudioDeviceTransportTypeUSB
  let virtual = kAudioDeviceTransportTypeVirtual
  let capture = FakeCapture()
  let microphone = Microphone(openSlot: DispatchSemaphore(value: 1))
  try await microphone.open(
    selecting: {
      try InputDevice.select(
        current: bluetooth, discover: { _, _, _ in [bluetooth, virtual, usb, builtin] }, transport: { $0 })
    },
    session: { selected in
      #expect(selected == builtin && capture.counts.withLock { $0 } == (0, 0))
      return capture
    })
  #expect(capture.counts.withLock { $0 } == (1, 0))
  for await _ in microphone.stop() {}
  let fallback = try InputDevice.select(
    current: bluetoothLE,
    discover: { types, media, position in
      #expect(types.contains(.microphone) && media == .audio && position == .unspecified)
      return types.contains(.external) ? [bluetoothLE, virtual, usb] : [bluetoothLE, virtual]
    }, transport: { $0 })
  #expect(fallback == usb)
  for current in [builtin, usb, virtual, kAudioDeviceTransportTypeUnknown] {
    #expect(
      try InputDevice.select(
        current: current,
        discover: { _, _, _ in
          Issue.record("Looked for a replacement for a non-Bluetooth input")
          return []
        }, transport: { $0 }) == current)
  }
}

@Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
func bluetoothRemainsTheFallbackWithoutBuiltInOrUSB(_ transport: UInt32) throws {
  #expect(
    try InputDevice.select(
      current: transport, discover: { _, _, _ in [transport, kAudioDeviceTransportTypeVirtual] },
      transport: { $0 })
      == transport)
}
