import AVFoundation
import CoreAudio
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

/// Counts what closing does, in place of the hardware.
private final class FakeEngine: CaptureEngine, @unchecked Sendable {
  let counts = Mutex((removedTaps: 0, stops: 0))
  let running = Mutex(true)
  var isRunning: Bool { running.withLock { $0 } }
  func removeTap() { counts.withLock { $0.removedTaps += 1 } }
  func stop() { counts.withLock { $0.stops += 1 } }
}

@Test func microphoneStoppedBeforeOpeningNeverOpens() async {
  // The stop is not awaited: it must already keep out an opening that comes right after it.
  let microphone = Microphone()
  let shutdown = microphone.stop()
  let engine = FakeEngine()
  #expect(throws: CancellationError.self) { try microphone.open(engine) { _ in Issue.record("Opened") } }
  await shutdown.value
  #expect(engine.counts.withLock { $0 } == (0, 0))
}

@Test(arguments: [true, false])
func microphoneClosesExactlyOnce(_ keepsRunning: Bool) async throws {
  let microphone = Microphone()
  let engine = FakeEngine()
  try microphone.open(engine) { _ in microphone.tapped = true }
  #expect(throws: CancellationError.self) {
    try microphone.open(FakeEngine()) { _ in Issue.record("Reopened") }
  }
  // A change that leaves the engine running is part of startup and is ignored; one that stops it ends
  // capture with one retry hint, however many changes and stops follow.
  engine.running.withLock { $0 = keepsRunning }
  let retries = Mutex(0)
  for _ in 0..<2 {
    microphone.configurationChanged {
      #expect($0 == .inputChanged)
      retries.withLock { $0 += 1 }
    }
  }
  let first = microphone.stop()
  await microphone.stop().value
  await first.value
  #expect(engine.counts.withLock { $0 } == (1, 1))
  #expect(retries.withLock { $0 } == (keepsRunning ? 0 : 1))
}

@MainActor @Test func microphoneStopWaitsForOpeningWithoutBlockingTheMainActor() async {
  let microphone = Microphone()
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let opening = Task.detached {
    try? microphone.open(FakeEngine()) { _ in
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
    }
  }
  #expect(await signalArrives(entered, within: 1))
  // This returns on the main actor even while opening is blocked on the background thread, and the
  // shutdown waits for the opening.
  let shutdown = microphone.stop()
  let closed = Mutex(false)
  let watcher = Task.detached {
    await shutdown.value
    closed.withLock { $0 = true }
  }
  try? await Task.sleep(for: .milliseconds(50))
  #expect(!closed.withLock { $0 })
  release.signal()
  await watcher.value
  await opening.value
  // Nothing opens after a stop.
  await Task.detached {
    _ = #expect(throws: CancellationError.self) {
      try microphone.open(FakeEngine()) { _ in Issue.record("Opened after stop") }
    }
  }.value
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

// Hardware rate and channels, then the node's: a 32 kHz USB microphone whose node reported 48 kHz first.
@Test(
  arguments: [
    [32000, 2, 48000, 2], [44100, 1, 48000, 1], [48000, 1, 48000, 2], [96000, 4, 48000, 2],
  ] as [[Double]])
func tapUsesTheHardwareRateAndChannels(_ formats: [Double]) throws {
  let hardware = try audio(UInt32(formats[1]), rate: formats[0]).format
  let tap = try Microphone.tapFormat(
    hardware: hardware, node: try audio(UInt32(formats[3]), rate: formats[2]).format)
  #expect(tap.sampleRate == formats[0] && tap.channelCount == UInt32(formats[1]))
  #expect(tap.commonFormat == .pcmFormatFloat32 && !tap.isInterleaved)
}

@Test func tapKeepsAnAgreeingNodeFormatAndRejectsUnusableHardware() throws {
  let builtin = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
  let node = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
  #expect(try Microphone.tapFormat(hardware: builtin, node: node) === node)
  let unusable = [
    AVAudioFormat(),
    try #require(AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)),
    try #require(AVAudioFormat(standardFormatWithSampleRate: .nan, channels: 1)),
  ]
  for hardware in unusable {
    #expect(throws: VoiceError.noMicrophone) { try Microphone.tapFormat(hardware: hardware, node: node) }
  }
}

@Test func thirtyTwoKilohertzStereoReachesTheAnalyzerFormat() throws {
  let input = try audio(2, rate: 32000)
  let tap = try Microphone.tapFormat(hardware: input.format, node: try audio(2).format)
  let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let conversion = try Conversion(input: tap, output: output)
  let result = try #require(try conversion.convert(input))
  #expect(result.format == output && result.frameLength > 2000 && result.frameLength <= 2400)
  #expect(abs(result.floatChannelData![0][500] - 0.75) < 0.001)
}

@Test func aBluetoothDefaultGivesWayToTheMacsOwnMicrophone() {
  let bluetooth = InputDevice(id: 1, transport: kAudioDeviceTransportTypeBluetooth)
  let bluetoothLE = InputDevice(id: 2, transport: kAudioDeviceTransportTypeBluetoothLE)
  let builtin = InputDevice(id: 3, transport: kAudioDeviceTransportTypeBuiltIn)
  let usb = InputDevice(id: 4, transport: kAudioDeviceTransportTypeUSB)
  let virtual = InputDevice(id: 5, transport: kAudioDeviceTransportTypeVirtual)
  let choose = InputDevice.avoidingBluetooth
  // Built-in first, then USB; never a virtual or another Bluetooth input.
  #expect(choose(1, [bluetooth, virtual, usb, builtin]) == 3)
  #expect(choose(2, [bluetoothLE, bluetooth, virtual, usb]) == 4)
  // No suitable alternative, a default that isn't Bluetooth, or no default: keep the system's choice.
  #expect(choose(1, [bluetooth, bluetoothLE, virtual]) == nil)
  #expect(choose(4, [bluetooth, builtin, usb]) == nil)
  #expect(choose(5, [virtual, builtin]) == nil)
  #expect(choose(nil, [bluetooth, builtin]) == nil)
  #expect(choose(9, [bluetooth, builtin]) == nil)
}
