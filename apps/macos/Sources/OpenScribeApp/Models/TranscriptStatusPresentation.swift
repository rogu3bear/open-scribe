import Foundation

/// What the transcript of one saved conversation is waiting for, in the words
/// the library row, the document notice, and Details all use. Rust's committed
/// posture comes first; the scheduler adds only intent (queued, held, asked).
struct TranscriptStatusPresentation: Equatable {
  /// The one useful action beside a notice.
  enum Action: Equatable {
    case cancel
    case transcribeNow
    case transcribe
    case tryAgain
    case setUp

    var title: String {
      switch self {
      case .cancel: "Cancel"
      case .transcribeNow: "Transcribe Now"
      case .transcribe: "Transcribe"
      case .tryAgain: "Try Again"
      case .setUp: TranscriptStatusPresentation.setUpTitle
      }
    }
  }

  struct Notice: Equatable {
    let message: String
    var isProblem = false
    var showsProgress = false
    var action: Action?
  }

  /// Facts outside the snapshot that change what the transcript waits for.
  struct Context: Equatable {
    var job: TranscriptionJobState?
    var isTranscribingHere = false
    /// The loaded document's availability, when this conversation is loaded.
    var loaded: NativeTranscriptAvailability?
    var modelInstalled = false
    var modelChecking = false
    var automatic = true
    var paused = false
    var canPrioritize = false
  }

  static let setUpTitle = "Set Up Transcription…"
  static let modelUnavailable =
    "Transcription is unavailable until a speech model is installed on this Mac."

  // MARK: Library line

  /// One short phrase for a library row: what is true about the transcript now.
  static func summary(_ transcript: RuntimeTranscriptPresentation) -> String {
    if transcript.documentAvailability == .partial {
      let document =
        "Transcript ready for \(transcript.finalTracks) of \(transcript.totalTracks) sources"
      return switch transcript.attempt {
      case .running: document + " · transcribing"
      case .failed: document + " · transcription failed"
      case .cancelled: document + " · transcription cancelled"
      case .preempted: document + " · paused for a recording"
      case .unknown: document + " · status unknown"
      case .none, .complete: document
      }
    }
    return switch transcript.state {
    case .none: "No transcript yet"
    case .running:
      transcript.totalChunks > 0
        ? "Transcribing, \(transcript.completedChunks) of \(transcript.totalChunks) parts"
        : "Transcribing"
    case .final:
      switch transcript.attempt {
      case .running: "Transcript ready · retranscribing"
      case .failed: "Transcript ready · retranscription failed"
      case .cancelled: "Transcript ready · retranscription cancelled"
      case .preempted: "Transcript ready · retranscription paused for a recording"
      case .unknown: "Transcript ready · status unknown"
      case .none, .complete: "Transcript ready"
      }
    case .partial:
      "Transcript ready for \(transcript.finalTracks) of \(transcript.totalTracks) sources"
    case .failed: "Transcription failed"
    case .cancelled:
      transcript.attempt == .preempted
        ? "Transcription paused for a recording" : "Transcription cancelled"
    case .unknown: "Transcript status unknown"
    }
  }

  /// The row's phrase with the scheduler's intent added. It never changes
  /// availability or decides eligibility.
  static func line(
    _ transcript: RuntimeTranscriptPresentation, job: TranscriptionJobState?
  ) -> (symbol: String, text: String) {
    let readable =
      transcript.documentAvailability == .final || transcript.documentAvailability == .partial
    let summary = summary(transcript)
    func message(_ text: String) -> String { readable ? summary + " · " + text : text }
    switch job {
    case .queued(let position, _):
      return (
        "clock",
        message(position == 1 ? "transcribing next" : "waiting to transcribe, \(position) in line")
      )
    case .running where transcript.attempt != .running:
      return ("ellipsis.circle", message("starting to transcribe"))
    case .failed where transcript.attempt != .failed:
      return ("exclamationmark.circle", message("transcription failed"))
    case .cancelled where transcript.attempt != .cancelled:
      return ("minus.circle", message("transcription cancelled"))
    case .preempted where transcript.attempt != .preempted:
      return ("pause.circle", message("paused for a recording"))
    case .deferred:
      return ("clock", message("waiting to transcribe"))
    case .incomplete:
      return ("text.badge.plus", message("some sources still need transcription"))
    default:
      let symbol =
        transcript.attempt == .running
        ? "ellipsis.circle"
        : transcript.attempt == .failed || transcript.attempt == .unknown
          ? "exclamationmark.circle" : "text.alignleft"
      return (symbol, summary)
    }
  }

  // MARK: Sentences

  /// Why the latest run ended without a transcript. The audio is never affected.
  static func failureReason(_ failureClass: NativeTranscriptionFailureClass?) -> String {
    switch failureClass {
    case .invalidResult?, .staleReconciliation?:
      "The finished parts couldn't be put together. Trying again rebuilds the transcript from them."
    case .orphaned?:
      "Transcription was interrupted before it finished. Trying again continues from the finished parts."
    case .storageError?:
      "The transcript couldn't be stored. Finished parts are kept for another try."
    case .cancelled?:
      "Transcription was cancelled."
    case .modelUnavailable?:
      "The speech model is not installed."
    case .engineError?:
      "The speech engine stopped before it finished."
    case .resourceExhausted?:
      "The Mac ran out of memory or disk space while transcribing."
    case .inputUnavailable?:
      "The recorded audio couldn't be read for transcription."
    case .capturePreempted?, .superseded?, nil:
      "Transcription stopped before it finished."
    }
  }

  static func failed(_ failureClass: NativeTranscriptionFailureClass?) -> String {
    "Transcription failed. \(failureReason(failureClass)) The audio is unchanged."
  }

  static func queued(position: Int, hold: TranscriptionHold?) -> String {
    if let hold { return "Waiting to transcribe. \(hold.text)" }
    return position == 1 ? "Transcribing next." : "Waiting to transcribe, \(position) in line."
  }

  /// The loaded document's availability, as Details states it.
  static func availability(_ availability: NativeTranscriptAvailability) -> String {
    switch availability {
    case .final: "Final transcript"
    case .draft: "Draft — the final transcript isn't finished yet"
    case .failed: "Transcription failed. The audio is unchanged."
    case .unavailable: "No transcript yet."
    }
  }

  /// The last thing the scheduler did, until the next request replaces it.
  static func outcome(_ job: TranscriptionJobState?) -> (text: String, isProblem: Bool)? {
    switch job {
    case .finished(let message): (message, false)
    case .failed(let message): (message, true)
    case .cancelled: (SpeechFailurePresentation.outcomeText(.userCancelled), false)
    case .preempted: (SpeechFailurePresentation.outcomeText(.capturePreempted), false)
    case .deferred: (SpeechFailurePresentation.outcomeText(.deferred), false)
    case .incomplete: (SpeechFailurePresentation.outcomeText(.incomplete), false)
    case .queued?, .running?, nil: nil
    }
  }

  // MARK: Document notice

  /// What the document says above the transcript, with the one action that helps.
  static func notice(
    session: RuntimeSessionPresentation, context: Context
  ) -> Notice? {
    guard session.transcriptionUnavailableReason == nil, session.transcript.hasTranscribableAudio
    else { return nil }
    let hasDraft = session.transcript.hasDraftText
    let isFinal = session.transcript.documentAvailability == .final
    if context.isTranscribingHere || context.job == .running {
      return Notice(
        message: hasDraft ? "Making the final transcript on this Mac…" : "Transcribing on this Mac…",
        showsProgress: true, action: .cancel)
    }
    if case .queued(let position, let hold) = context.job {
      return Notice(
        message: queued(position: position, hold: hold),
        action: context.canPrioritize ? .transcribeNow : nil)
    }
    if context.loaded == .failed {
      return Notice(
        message: failed(session.transcript.failureClass), isProblem: true,
        action: context.modelInstalled ? .tryAgain : .setUp)
    }
    if case .failed(let message) = context.job {
      return Notice(message: message, isProblem: true, action: .tryAgain)
    }
    if !isFinal, !context.modelInstalled, !context.modelChecking {
      return Notice(
        message: hasDraft
          ? "This is the live draft. Add a speech model to make a more accurate transcript on this Mac."
          : "No transcript yet. Add a speech model to transcribe this recording on this Mac.",
        action: .setUp)
    }
    if !isFinal, context.modelInstalled, !context.automatic || context.paused {
      return Notice(
        message: hasDraft
          ? "This is the live draft. The final transcript hasn't been made yet."
          : "Not transcribed yet.",
        action: .transcribe)
    }
    if hasDraft, !isFinal {
      return Notice(message: "This is the live draft. Some words may be misheard.")
    }
    return nil
  }

  // MARK: Details

  /// The transcript line in Details: the committed state, with the reason when
  /// the latest run ended without a transcript.
  static func detail(
    session: RuntimeSessionPresentation, loaded: NativeTranscriptAvailability,
    loadedText: String, modelMissing: Bool
  ) -> String {
    if session.transcript.state == .final, session.transcript.attempt == .failed {
      return "Your current transcript is kept. Retranscribing failed. "
        + failureReason(session.transcript.attemptFailure)
    }
    if loaded == .failed { return failed(session.transcript.failureClass) }
    if modelMissing, loaded == .unavailable { return modelUnavailable }
    return loadedText
  }
}
