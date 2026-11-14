import Foundation

/// Rust's capture limits and source defaults, read once. Swift keeps no copies
/// of these values. Files that script/check_import_components.sh or
/// script/check_imported_audio_round_trip.sh compile without this file call
/// `nativeCapturePolicy()` directly.
extension NativeCapturePolicy {
  static let current = nativeCapturePolicy()

  var sampleRate: Double { Double(sampleRateHz) }

  func source(_ kind: NativeMediaSourceKind) -> NativeSourceDefaults {
    switch kind {
    case .microphone: microphone
    case .applicationAudio: applicationAudio
    case .systemAudio: systemAudio
    }
  }
}
