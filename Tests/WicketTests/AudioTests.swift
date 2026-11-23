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

  init(running: Bool = true) { isRunning = running }
  func startRunning() { counts.withLock { $0.starts += 1 } }
  func stopRunning() { counts.withLock { $0.stops += 1 } }
}

@Test func microphoneStoppedBeforeOpeningNeverOpens() async {
  // The close is already queued, even when the caller hasn't waited for it.
  let microphone = Microphone()
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
  let microphone = Microphone()
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
  for _ in 0..<2 {
    microphone.captureEnded {
      #expect($0 == .inputChanged)
      retries.withLock { $0 += 1 }
    }
  }
  for await _ in microphone.stop() {}
  for await _ in microphone.stop() {}
  #expect(capture.counts.withLock { $0 } == (1, 1))
  #expect(retries.withLock { $0 } == 1)
}

@Test func microphoneThatFailsToRunClosesAndReportsStartupFailure() async {
  let microphone = Microphone()
  let capture = FakeCapture(running: false)
  await #expect(throws: VoiceError.microphoneStartFailed) {
    try await microphone.open(selecting: {}, session: { _ in capture })
  }
  #expect(capture.counts.withLock { $0 } == (1, 1))
}

@MainActor @Test func microphoneStopWaitsForOpeningWithoutBlockingTheMainActor() async {
  let microphone = Microphone()
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  var stoppedWaiting = false
  // The opening stays blocked until the test releases it, so a starved machine cannot let it finish
  // early. The limits are watchdogs for a hung harness, not timings the test depends on.
  let opening = Task {
    defer { stoppedWaiting = true }
    try await microphone.open(
      selecting: {},
      session: { _ in
        entered.signal()
        if release.wait(timeout: .now() + 60) == .timedOut {
          Issue.record("Harness timeout: the opening was never released")
        }
        return FakeCapture()
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
  release.signal()
  await watcher.value
  await #expect(throws: CancellationError.self) { try await opening.value }
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
  let unsupported = try #require(
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false))
  #expect(throws: VoiceError.conversionFailed) { try Conversion(input: unsupported, output: output) }
}

@Test func thirtyTwoKilohertzStereoReachesTheAnalyzerFormat() throws {
  let input = try audio(2, rate: 32000)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
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

@Test func bluetoothInputIsReplacedBeforeTheCaptureSessionIsMade() async throws {
  let bluetooth = kAudioDeviceTransportTypeBluetooth
  let bluetoothLE = kAudioDeviceTransportTypeBluetoothLE
  let builtin = kAudioDeviceTransportTypeBuiltIn
  let usb = kAudioDeviceTransportTypeUSB
  let virtual = kAudioDeviceTransportTypeVirtual
  let capture = FakeCapture()
  let microphone = Microphone()
  try await microphone.open(
    selecting: {
      InputDevice.avoidingBluetooth(bluetooth, [bluetooth, virtual, usb, builtin], transport: { $0 })
    },
    session: { selected in
      #expect(selected == builtin && capture.counts.withLock { $0 } == (0, 0))
      return capture
    })
  #expect(capture.counts.withLock { $0 } == (1, 0))
  for await _ in microphone.stop() {}
  #expect(InputDevice.avoidingBluetooth(bluetoothLE, [bluetooth, virtual, usb], transport: { $0 }) == usb)
  #expect(InputDevice.avoidingBluetooth(bluetooth, [bluetoothLE, virtual], transport: { $0 }) == bluetooth)
  #expect(InputDevice.avoidingBluetooth(usb, [bluetooth, builtin, usb], transport: { $0 }) == usb)
  #expect(InputDevice.avoidingBluetooth(virtual, [bluetooth, builtin], transport: { $0 }) == virtual)
}
