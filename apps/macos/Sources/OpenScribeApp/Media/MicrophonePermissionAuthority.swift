@preconcurrency import AVFoundation

enum MicrophonePermissionState: String, Equatable, Sendable {
  case notDetermined
  case denied
  case restricted
  case authorized
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
  var currentState: MicrophonePermissionState { get }
  func request() async -> MicrophonePermissionState
}

/// The sole production adapter for microphone TCC state. It exposes only the
/// coarse permission truth needed by the app; capture startup remains a
/// separate, explicit operation.
@MainActor
final class AVFoundationMicrophonePermissionAuthority: MicrophonePermissionProviding {
  var currentState: MicrophonePermissionState {
    Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
  }

  func request() async -> MicrophonePermissionState {
    guard currentState == .notDetermined else { return currentState }
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
    return granted ? .authorized : .denied
  }

  nonisolated static func map(_ status: AVAuthorizationStatus) -> MicrophonePermissionState {
    switch status {
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    case .authorized: .authorized
    @unknown default: .denied
    }
  }
}
