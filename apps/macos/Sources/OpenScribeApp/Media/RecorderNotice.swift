import Foundation

/// What the recorder tells the person recording. The recorder emits a notice
/// and `text` is the only place its wording lives. Recorder suites, the
/// injected proofs and the microphone-restore acceptance criteria assert many
/// of these sentences verbatim, including the adapter error names a source
/// failure quotes.
indirect enum RecorderNotice: Equatable, Sendable {
  /// What the rest of the recording is doing, said after a microphone notice.
  enum Continuation: Equatable, Sendable {
    /// The named source is still recording.
    case recording(source: String)
    /// A restore was refused while other audio keeps recording.
    case existingAudioRecording
    case paused
    case resuming
  }

  case microphoneStopped(Continuation)
  case microphoneNotRestored(Continuation)
  case microphoneAccessWithdrawn(Continuation)
  case microphoneAccessOff(Continuation)
  case microphoneAccessNeededToRejoin
  case differentMicrophone(Continuation)
  case microphoneUnavailable(Continuation)
  case noSpaceToRestoreMicrophone(Continuation)
  case restoreSpaceUnchecked(Continuation)
  case microphoneOnlyAfterLoss
  case sourceStopped(source: String, cause: RecorderNotice)
  case sourceAccessWithdrawn(source: String)
  case resumeMicrophoneAccessUnavailable
  case resumeNoSpace
  case resumeFailed(RecorderNotice)
  case pausedRecordingNotFinished
  case pauseNotSaved
  case pausedForSleep
  case stoppedAtReserve
  case stoppedForReserveAfterFailure
  case storageUnchecked
  case sourceChangeNotSaved
  case markerNotSaved
  case microphoneAccess(MicrophonePermissionState)
  case systemAudioUnavailable(RecorderNotice)
  case systemAudioNotStopped
  case noMicrophoneSample
  case noSourceSample
  case microphoneStoppedRecordingKept
  case microphoneNotSealed
  case failedSourceSealedContinuationUnconfirmed(RecorderNotice)
  case failedSourceNotSealed(RecorderNotice)
  case microphoneRouteStopped
  case applicationExited
  case microphonePermissionWithdrawnAudioKept
  case approvedMicrophoneDidNotStart
  case restoreDeadlinePassed
  /// The session's interruption could not be confirmed after `notice`.
  case recoveryUnconfirmed(RecorderNotice)
  /// An error's own words, passed on unchanged.
  case detail(String)

  var text: String {
    switch self {
    case .microphoneStopped(let next): "The microphone stopped. \(next.text)"
    case .microphoneNotRestored(let next): "The microphone could not be restored. \(next.text)"
    case .microphoneAccessWithdrawn(let next): "Microphone access was withdrawn. \(next.text)"
    case .microphoneAccessOff(let next):
      "Microphone access is off. Enable it in System Settings. \(next.text)"
    case .microphoneAccessNeededToRejoin:
      "Microphone access is needed before the microphone can rejoin."
    case .differentMicrophone(let next): "This is a different microphone. \(next.text)"
    case .microphoneUnavailable(let next):
      "The selected microphone is not available. \(next.text)"
    case .noSpaceToRestoreMicrophone(let next):
      "Not enough free space to restore the microphone. \(next.text)"
    case .restoreSpaceUnchecked(let next):
      "Available space could not be checked. The microphone was not restored. \(next.text) Try again."
    case .microphoneOnlyAfterLoss:
      "The microphone stopped earlier in this recording, so Microphone only has nothing to record. The previous selection is retained."
    case .sourceStopped(let source, let cause):
      "\(source) stopped. Remaining audio is still recording. \(cause.text)"
    case .sourceAccessWithdrawn(let source):
      "\(source) permission was withdrawn. Remaining audio is still recording."
    case .resumeMicrophoneAccessUnavailable:
      "Microphone access is unavailable. The recording remains paused."
    case .resumeNoSpace:
      "Not enough free space to resume. The recording is still paused; free space and try again."
    case .resumeFailed(let cause):
      "The recording could not resume and remains paused. \(cause.text)"
    case .pausedRecordingNotFinished:
      "The paused recording could not be finished. Its audio is preserved."
    case .pauseNotSaved: "The pause could not be saved. Recording continues."
    case .pausedForSleep:
      "Recording paused because the Mac went to sleep. Audio recorded so far is saved; resume when ready."
    case .stoppedAtReserve:
      "Recording stopped at the storage reserve. Existing audio is preserved."
    case .stoppedForReserveAfterFailure:
      "Recording stopped because storage reached its reserve. Existing audio was preserved."
    case .storageUnchecked:
      "Storage availability could not be checked. Recording was stopped to preserve audio."
    case .sourceChangeNotSaved:
      "The source change could not be saved. The previous selection is kept."
    case .markerNotSaved: "The marker could not be saved."
    case .microphoneAccess(let state):
      "Microphone access is \(Self.word(for: state)). Enable it in System Settings."
    case .systemAudioUnavailable(let cause):
      "System audio access or the selected source is unavailable. \(cause.text)"
    case .systemAudioNotStopped:
      "System audio could not be stopped safely. The recording was kept for recovery."
    case .noMicrophoneSample:
      "No microphone sample was saved. The recording was kept for recovery."
    case .noSourceSample:
      "A required source produced no durable sample. Recovery state was preserved."
    case .microphoneStoppedRecordingKept:
      "The microphone stopped and the recording was preserved."
    case .microphoneNotSealed:
      "The microphone could not be sealed safely. Existing audio was preserved."
    case .failedSourceSealedContinuationUnconfirmed(let cause):
      "The failed source was sealed, but continued recording could not be confirmed. \(cause.text)"
    case .failedSourceNotSealed(let cause):
      "The failed source could not be sealed safely. \(cause.text)"
    case .microphoneRouteStopped: "The microphone audio route stopped."
    case .applicationExited: "The selected application exited."
    case .microphonePermissionWithdrawnAudioKept:
      "Microphone permission was withdrawn. Audio recorded so far is preserved."
    case .approvedMicrophoneDidNotStart: "The approved microphone could not start."
    case .restoreDeadlinePassed:
      "The microphone did not provide audio before the restore deadline."
    case .recoveryUnconfirmed(let notice): "\(notice.text) Recovery state could not be confirmed."
    case .detail(let text): text
    }
  }

  private static func word(for state: MicrophonePermissionState) -> String {
    switch state {
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined, .authorized: "not granted"
    }
  }
}

extension RecorderNotice.Continuation {
  var text: String {
    switch self {
    case .recording(let source): "\(source) is still recording."
    case .existingAudioRecording: "Existing audio is still recording."
    case .paused: "The recording is paused."
    case .resuming: "The recording is resuming."
    }
  }
}
