import CoreAudio
import Foundation

struct MicrophoneDevice: Equatable, Sendable {
  var id: AudioDeviceID = 0
  let uid: String, name: String
  let transport: UInt32
  var hasInput = true, isDefault = false
  var wired: Bool {
    [
      kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
      kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
    ].contains(transport)
  }
  static func select(_ devices: [Self], uid: String?) -> Self? {
    let inputs = devices.filter(\.hasInput)
    if let uid, let chosen = inputs.first(where: { $0.uid == uid }) { return chosen }
    let preferred = inputs.first(where: \.isDefault)
    if let preferred, preferred.wired { return preferred }
    return inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
      ?? inputs.first { $0.transport == kAudioDeviceTransportTypeUSB }
      ?? inputs.first { $0.wired }
      ?? preferred.flatMap { device in
        [
          kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
          kAudioDeviceTransportTypeAutoAggregate,
          kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
        ].contains(device.transport) ? nil : device
      }
  }
}

/// Property getters only. Enumerating inputs never opens a device or changes system defaults.
enum MicrophoneDevices {
  static func available() -> [MicrophoneDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let defaultID = number(system, kAudioHardwarePropertyDefaultInputDevice)
    return ids(system, kAudioHardwarePropertyDevices).compactMap { id in
      guard !ids(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput).isEmpty,
        let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      return MicrophoneDevice(
        id: id, uid: uid, name: name,
        transport: number(id, kAudioDevicePropertyTransportType), isDefault: id == defaultID)
    }
  }
  private static func ids(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [UInt32] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
    let status = values.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<UInt32>.size)) : []
  }
  private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
  }
  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value as String? : nil
  }
}
