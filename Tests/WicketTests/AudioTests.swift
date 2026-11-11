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

@Test func microphoneStopBeforeStartAndDoubleStart() async throws {
  let stopped = Microphone()
  await stopped.stop()
  var opened = 0
  #expect(throws: CancellationError.self) {
    try stopped.start {
      opened += 1
      return {}
    }
  }
  #expect(opened == 0)
  let microphone = Microphone()
  let closed = Mutex(0)
  try microphone.start {
    opened += 1
    return { closed.withLock { $0 += 1 } }
  }
  #expect(throws: CancellationError.self) {
    try microphone.start {
      opened += 1
      return {}
    }
  }
  #expect(opened == 1)
  await microphone.stop()
  await microphone.stop()
  #expect(closed.withLock { $0 } == 1)
}

@MainActor @Test func microphoneStopWaitsForOpeningWithoutBlockingTheMainActor() async {
  let microphone = Microphone()
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let closed = Mutex(0)
  let opening = Task.detached {
    try? microphone.start {
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
      return { closed.withLock { $0 += 1 } }
    }
  }
  #expect(await signalArrives(entered, within: 1))
  // This returns on the main actor even while open is blocked on the background thread.
  let shutdown = microphone.requestStop()
  #expect(closed.withLock { $0 } == 0)
  #expect(throws: CancellationError.self) {
    try microphone.start {
      Issue.record("Opened after stop")
      return {}
    }
  }
  release.signal()
  await shutdown.value
  await opening.value
  await microphone.stop()
  #expect(closed.withLock { $0 } == 1)
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

@Test func automaticMicrophoneAvoidsBluetoothAndHonorsSavedUID() {
  let bluetooth = MicrophoneDevice(
    uid: "bt", name: "Headset", transport: kAudioDeviceTransportTypeBluetooth, isDefault: true)
  let builtin = MicrophoneDevice(uid: "built", name: "MacBook", transport: kAudioDeviceTransportTypeBuiltIn)
  let usb = MicrophoneDevice(
    uid: "usb", name: "USB", transport: kAudioDeviceTransportTypeUSB, isDefault: true)
  #expect(MicrophoneDevice.select([bluetooth, builtin], uid: nil) == builtin)
  #expect(MicrophoneDevice.select([bluetooth], uid: nil) == bluetooth)
  #expect(MicrophoneDevice.select([builtin, usb], uid: nil) == usb)
  #expect(MicrophoneDevice.select([bluetooth, builtin], uid: "missing") == builtin)
  #expect(MicrophoneDevice.select([bluetooth, builtin], uid: "bt") == bluetooth)
  #expect(MicrophoneDevice.select([bluetooth, usb], uid: nil) == usb)
  #expect(MicrophoneDevice.select([], uid: nil) == nil)
  var output = builtin
  output.hasInput = false
  #expect(MicrophoneDevice.select([output], uid: "built") == nil)
  var le = bluetooth
  le = MicrophoneDevice(
    uid: le.uid, name: le.name, transport: kAudioDeviceTransportTypeBluetoothLE, isDefault: true)
  #expect(MicrophoneDevice.select([le, builtin], uid: nil) == builtin)
}

@Test func microphoneFormatsMustAgreeBeforeInstallingATap() throws {
  let builtin = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
  let headset = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
  let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
  try Microphone.validate(input: builtin, output: builtin)
  for other in [headset, stereo, AVAudioFormat()] {
    #expect(throws: VoiceError.noMicrophone) { try Microphone.validate(input: builtin, output: other) }
    #expect(throws: VoiceError.noMicrophone) { try Microphone.validate(input: other, output: builtin) }
  }
}

@Test(arguments: [
  kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
  kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeContinuityCaptureWired,
  kAudioDeviceTransportTypeContinuityCaptureWireless,
])
func automaticNeverChoosesVirtualAggregateOrContinuityInputs(_ transport: UInt32) {
  let excluded = MicrophoneDevice(uid: "excluded", name: "Other input", transport: transport, isDefault: true)
  let builtin = MicrophoneDevice(uid: "built", name: "MacBook", transport: kAudioDeviceTransportTypeBuiltIn)
  let usb = MicrophoneDevice(uid: "usb", name: "USB", transport: kAudioDeviceTransportTypeUSB)
  #expect(MicrophoneDevice.select([excluded, usb, builtin], uid: nil) == builtin)
  #expect(MicrophoneDevice.select([excluded, usb], uid: nil) == usb)
  #expect(MicrophoneDevice.select([excluded], uid: nil) == nil)
  #expect(MicrophoneDevice.select([excluded, builtin], uid: excluded.uid) == excluded)
}
