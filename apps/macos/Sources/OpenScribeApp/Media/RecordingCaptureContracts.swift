import Foundation

typealias MicrophoneFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias MicrophoneHealthHandler = @Sendable (MicrophoneSourceHealthObservation) -> Void
typealias MicrophoneFailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void
typealias SystemAudioFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias SystemAudioFailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

protocol ManagedSegmentWriting: CapturedAudioWriting {
  var authorization: NativeMediaOpenAuthorization { get }
  func receipt() throws -> NativeMediaOpenReceipt
  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt
  /// Rust's durable acceptance of `segmentId`'s first sample when this writer
  /// already submitted it on its own queue; nil when the caller must submit.
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence?
}

extension ManagedSegmentWriting {
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence? { nil }
}

extension ManagedCAFWriter: ManagedSegmentWriting {}

protocol MicrophoneCapturing: AnyObject, Sendable {
  func bindInput(to device: MicrophoneDeviceIdentity?) throws
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler,
    onFailure: @escaping MicrophoneFailureHandler
  ) throws
  func stop() -> UInt64?
}

/// Synthetic capture fixtures have no physical device to bind.
extension MicrophoneCapturing {
  func bindInput(to device: MicrophoneDeviceIdentity?) throws {}
}

extension MicrophoneCaptureAdapter: MicrophoneCapturing {}

protocol SystemAudioCapturing: AnyObject, Sendable {
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws
  func stop() async throws -> UInt64?
}

extension SystemAudioCaptureAdapter: SystemAudioCapturing {}
