import Foundation

typealias CaptureFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias MicrophoneFirstSampleHandler = CaptureFirstSampleHandler
typealias MicrophoneHealthHandler = @Sendable (MicrophoneSourceHealthObservation) -> Void
typealias MicrophoneFailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void
typealias SystemAudioFirstSampleHandler = CaptureFirstSampleHandler
typealias SystemAudioFailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

protocol ManagedSegmentWriting: CapturedAudioWriting {
  var authorization: NativeMediaOpenAuthorization { get }
  func receipt() throws -> NativeMediaOpenReceipt
  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt
  /// Rust's durable acceptance of `segmentId`'s first sample when this writer
  /// already submitted it on its own queue; nil when the caller must submit.
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence?
  /// The first receipt this writer submitted itself, if any.
  func firstAcceptedReceipt() -> NativeFirstSampleReceipt?
}

extension ManagedSegmentWriting {
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence? { nil }
  func firstAcceptedReceipt() -> NativeFirstSampleReceipt? { nil }
}

extension ManagedCAFWriter: ManagedSegmentWriting {}

/// A source the recorder starts and stops. Live captions listen to the audio
/// it has written through `liveAudio`.
protocol AudioCaptureSource: AnyObject, Sendable {
  var liveAudio: LiveAudioListenerSlot { get }
}

protocol MicrophoneCapturing: AudioCaptureSource {
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

protocol SystemAudioCapturing: AudioCaptureSource {
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws
  func stop() async throws -> UInt64?
}

extension SystemAudioCaptureAdapter: SystemAudioCapturing {}

/// Points where Rust has made a recording step durable.
enum RecordingBoundary: String, Sendable {
  case preparation, recording, stop, seal, processing
}

/// Told when a recording reaches a boundary. Processing is reported from the
/// mixdown queue, so observers must be thread-safe.
protocol RecordingObserver: AnyObject, Sendable {
  func recording(reached boundary: RecordingBoundary, sessionId: String)
}
