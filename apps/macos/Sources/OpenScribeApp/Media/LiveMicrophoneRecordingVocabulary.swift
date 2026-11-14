import Foundation

/// The recorder's phases. `rawValue` reaches diagnostic logs.
enum LiveMicrophoneRecordingPhase: String, Equatable, Sendable {
  case idle
  case requestingPermission
  case preparing
  case starting
  case capturing
  case pausing
  case paused
  case stopping
  case saved
  case failed
}

/// Why the recorder refused Rust's evidence. `failureCode` reaches logs.
enum LiveMicrophoneRecordingError: LocalizedError {
  case invalidPreparation
  case invalidMediaOpen
  case invalidFirstSample
  case invalidRecordingAuthority
  case invalidSegmentSeal
  case invalidSourcePlan
  case invalidSourceFailure
  case missingFailedSourceSample
  case managedRootUnavailable

  /// Plain wording for the person recording. `invalidSourceFailure` keeps its
  /// text because LiveMicrophoneRecordingControllerTests asserts it.
  var errorDescription: String? {
    switch self {
    case .invalidPreparation: "The recording could not be prepared."
    case .invalidMediaOpen: "The audio files could not be opened."
    case .invalidFirstSample: "The first recorded audio could not be saved."
    case .invalidRecordingAuthority: "Not every audio source started recording."
    case .invalidSegmentSeal: "The recorded audio could not be closed."
    case .invalidSourcePlan: "The audio sources could not be set up."
    case .invalidSourceFailure: "Rust did not confirm degraded source-failure evidence."
    case .missingFailedSourceSample: "The stopped source had no saved audio."
    case .managedRootUnavailable: "The recordings folder is unavailable."
    }
  }

  var failureCode: RecorderFailureCode {
    switch self {
    case .invalidPreparation: .durablePreparation
    case .invalidMediaOpen: .mediaOpenEvidence
    case .invalidFirstSample: .firstSampleEvidence
    case .invalidRecordingAuthority: .recordingAuthority
    case .invalidSegmentSeal: .segmentSeal
    case .invalidSourcePlan: .requiredSourcePlan
    case .invalidSourceFailure: .sourceFailureEvidence
    case .missingFailedSourceSample: .sourceFailureSample
    case .managedRootUnavailable: .managedRoot
    }
  }
}

extension RecorderFailureCode {
  init(permission: MicrophonePermissionState) {
    switch permission {
    case .notDetermined: self = .permissionNotDetermined
    case .denied: self = .permissionDenied
    case .restricted: self = .permissionRestricted
    case .authorized: self = .permissionAuthorized
    }
  }

  init(_ error: MicrophoneCaptureAdapterError) {
    switch error {
    case .invalidInputFormat: self = .captureInvalidInputFormat
    case .alreadyStarted: self = .captureAlreadyStarted
    case .bufferPoolExhausted: self = .captureBufferPoolExhausted
    case .bufferFrameCapacityExceeded: self = .captureBufferFrameCapacityExceeded
    case .bufferLayoutMismatch: self = .captureBufferLayoutMismatch
    case .bufferByteSizeMismatch: self = .captureBufferByteSizeMismatch
    case .missingHostTime: self = .captureMissingHostTime
    case .writerFailed: self = .captureWriterFailed
    case .inputDeviceUnavailable: self = .captureInputDeviceUnavailable
    case .inputDeviceChanged: self = .captureInputDeviceChanged
    }
  }

  init(_ error: SystemAudioCaptureAdapterError) {
    switch error {
    case .noDisplayAvailable: self = .systemAudioNoDisplayAvailable
    case .alreadyStarted: self = .systemAudioAlreadyStarted
    case .outputRegistrationFailed: self = .systemAudioOutputRegistrationFailed
    case .invalidSampleBuffer: self = .systemAudioInvalidSampleBuffer
    case .writerFailed: self = .systemAudioWriterFailed
    case .streamStopped: self = .systemAudioStreamStopped
    case .userStopped: self = .systemAudioUserStopped
    case .permissionDenied: self = .systemAudioPermissionDenied
    }
  }
}
