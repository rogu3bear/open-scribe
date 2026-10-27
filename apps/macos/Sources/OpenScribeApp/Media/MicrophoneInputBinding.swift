import CoreAudio
import Foundation

/// Resolving a UID and selecting it are separate steps: the device can disappear
/// or its numeric ID can be reused in between. Read back the actual selected UID.
struct MicrophoneInputBinding: Sendable {
  let resolve: @Sendable (String) throws -> AudioDeviceID
  let select: @Sendable (AudioDeviceID) throws -> Void
  let selectedUID: @Sendable () throws -> String

  func bind(_ device: MicrophoneDeviceIdentity?) throws {
    guard let device, !device.uniqueID.isEmpty else {
      throw MicrophoneCaptureAdapterError.inputDeviceUnavailable
    }
    let id = try resolve(device.uniqueID)
    guard id != kAudioObjectUnknown else {
      throw MicrophoneCaptureAdapterError.inputDeviceUnavailable
    }
    try select(id)
    try validate(device)
  }

  func validate(_ device: MicrophoneDeviceIdentity) throws {
    guard try selectedUID() == device.uniqueID else {
      throw MicrophoneCaptureAdapterError.inputDeviceChanged
    }
  }
}

enum CoreAudioInputDevice {
  static func currentInput() throws -> MicrophoneDeviceIdentity {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        &size, &device) == noErr, device != kAudioObjectUnknown
    else { throw MicrophoneCaptureAdapterError.inputDeviceUnavailable }
    return MicrophoneDeviceIdentity(
      uniqueID: try uniqueID(device),
      localizedName: (try? stringValue(kAudioObjectPropertyName, device: device)) ?? "Microphone")
  }

  static func resolve(_ uid: String) throws -> AudioDeviceID {
    var qualifier = uid as CFString
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &qualifier) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size),
        pointer, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown else {
      throw MicrophoneCaptureAdapterError.inputDeviceUnavailable
    }
    return device
  }

  static func uniqueID(_ device: AudioDeviceID) throws -> String {
    try stringValue(kAudioDevicePropertyDeviceUID, device: device)
  }

  private static func stringValue(_ selector: AudioObjectPropertySelector, device: AudioDeviceID)
    throws -> String
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let value else {
      throw MicrophoneCaptureAdapterError.inputDeviceUnavailable
    }
    // Both UID and object-name properties transfer a retained CFString.
    return value.takeRetainedValue() as String
  }
}
