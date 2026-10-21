import Foundation

/// Shared by the production consumer and offscreen checks. Human messages
/// derive from typed failures; engine strings and file paths are never shown.
enum SpeechFailurePresentation {
  static func text(for result: NativeTranscriptionResult) -> String {
    if result.outcome == .failed || result.outcome == .deferred,
      let failure = result.failure
    {
      return describe(failure)
    }
    return outcomeText(result.outcome)
  }

  static func outcomeText(_ outcome: NativeWorkOutcome) -> String {
    switch outcome {
    case .completed: "Transcript ready."
    case .userCancelled: "Transcription was cancelled. The recorded audio is unchanged."
    case .capturePreempted: "Transcription yielded to capture. Finished parts are kept."
    case .failed: "Transcription did not finish. The recorded audio is unchanged."
    case .deferred: "Transcription is waiting to start."
    case .incomplete: "Saved parts were checked. Some tracks still need transcription."
    }
  }

  static func code(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    switch error as? NativeSpeechError {
    case .ModelNotInstalled: return "ModelNotInstalled"
    case .ModelRejected: return "ModelRejected"
    case .ModelReadiness: return "ModelReadiness"
    case .NoTranscribableAudio: return "NoTranscribableAudio"
    case .DecodedAudioRejected: return "DecodedAudioRejected"
    case .DecodedAudioFormatRejected: return "DecodedAudioFormatRejected"
    case .DecodedAudioChannelsMismatch: return "DecodedAudioChannelsMismatch"
    case .DecodedAudioLengthMismatch: return "DecodedAudioLengthMismatch"
    case .EvidenceChanged: return "EvidenceChanged"
    case .Cancelled: return "Cancelled"
    case .CapturePreempted: return "CapturePreempted"
    case .Deferred: return "Deferred"
    case .TranscriptionFailed: return "TranscriptionFailed"
    case .StorageFailure: return "StorageFailure"
    case .none: return "unavailable"
    }
  }

  static func diagnostic(_ error: NativeSpeechError) -> String {
    switch error {
    case .DecodedAudioChannelsMismatch(let expected, let actual):
      return "\(code(error)) expected_channels=\(expected) actual_channels=\(actual)"
    case .DecodedAudioLengthMismatch(let expected, let actual):
      return "\(code(error)) expected_frames=\(expected) actual_frames=\(actual)"
    default: return code(error)
    }
  }

  static func describe(_ error: Error) -> String {
    switch error as? NativeSpeechError {
    case .ModelNotInstalled:
      return "No verified speech model is installed."
    case .ModelRejected(let reason), .ModelReadiness(_, let reason):
      return "The model file was not installed: \(rejection(reason))."
    case .NoTranscribableAudio:
      return "This conversation has no recorded audio to transcribe."
    case .DecodedAudioRejected:
      return
        "The imported audio could not be prepared for transcription. Your original recording is unchanged."
    case .DecodedAudioFormatRejected:
      return "The decoded audio has an unsupported format. Your original recording is unchanged."
    case .DecodedAudioChannelsMismatch:
      return
        "The decoded audio has a different number of channels from the saved recording. Your original recording is unchanged."
    case .DecodedAudioLengthMismatch:
      return
        "The decoded audio length does not match the saved recording. Your original recording is unchanged."
    case .EvidenceChanged:
      return
        "Saved conversation data no longer matches its verified state. Transcription stopped without changing any recording."
    case .Cancelled: return outcomeText(.userCancelled)
    case .CapturePreempted: return outcomeText(.capturePreempted)
    case .Deferred: return outcomeText(.deferred)
    case .TranscriptionFailed(let reason) where reason == "transcript_validation":
      return
        "The transcript could not be assembled consistently. Your audio and any finished transcript parts are unchanged."
    case .TranscriptionFailed: return outcomeText(.failed)
    case .StorageFailure:
      return "Open Scribe could not reach the conversation library."
    case .none:
      return "Open Scribe could not complete this operation. Your original recording is unchanged."
    }
  }

  static func rejection(_ reason: String) -> String {
    switch reason {
    case "truncated": "it is shorter than the published file"
    case "oversized": "it is longer than the published file"
    case "digest_mismatch": "its SHA-256 does not match the published file"
    case "not_ggml", "wrong_model": "it is not the listed model"
    case "incompatible_engine", "engine_version": "it does not match this build's speech engine"
    case "model_rejected", "self_test_failed": "the speech engine could not run it"
    default: "it could not be read and checked"
    }
  }
}
