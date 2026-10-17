import AppKit

struct RuntimeSourcePresentation: Equatable, Sendable {
  let kind: NativeMediaSourceKind
  let name: String
  let lifecycle: String

  init(native: NativeRuntimeSourceSnapshot) {
    kind = native.kind
    name = native.displayName
    lifecycle = native.lifecycle
  }

  init(kind: NativeMediaSourceKind, name: String, lifecycle: String) {
    self.kind = kind
    self.name = name
    self.lifecycle = lifecycle
  }

  var stateText: String {
    switch lifecycle {
    case "required": "Waiting"
    case "opening": "Opening"
    case "open": "Ready"
    case "capturing": "Capturing"
    case "failed": "Failed"
    case "sealed": "Saved"
    default: lifecycle.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  var symbolName: String {
    switch kind {
    case .microphone: "mic"
    case .applicationAudio: "macwindow"
    case .systemAudio: "speaker.wave.2"
    }
  }
}

struct RuntimePlayableMediaPresentation: Equatable, Sendable {
  let sourceDisplayName: String
  let availability: String
  let durationNanoseconds: UInt64
  let sampleCount: UInt64
  let byteLength: UInt64

  init(native: NativeRuntimePlayableMediaSnapshot) {
    sourceDisplayName = native.sourceDisplayName
    availability = native.availability
    durationNanoseconds = native.durationNanoseconds
    sampleCount = native.sampleCount
    byteLength = native.byteLength
  }

  var isPlayable: Bool {
    availability == "available" && sampleCount > 0 && byteLength > 0
  }

  var durationText: String {
    guard durationNanoseconds >= 1_000_000_000 else { return "Less than 1 second" }
    let elapsedSeconds = durationNanoseconds / 1_000_000_000
    let hours = elapsedSeconds / 3_600
    let minutes = (elapsedSeconds % 3_600) / 60
    let seconds = elapsedSeconds % 60
    return String(format: "%02llu:%02llu:%02llu", hours, minutes, seconds)
  }

  var statusText: String {
    switch availability {
    case "available": "Ready to play"
    case "unavailable": "Audio unavailable"
    case "corrupt": "Audio appears corrupt"
    default: "Playback unavailable"
    }
  }
}

struct RecoveredTrackPresentation: Identifiable {
  let playableSession: NativeRecoveredPlayableSession

  var source: RuntimeSourcePresentation {
    RuntimeSourcePresentation(
      kind: playableSession.sourceKind,
      name: playableSession.sourceDisplayName,
      lifecycle: "sealed"
    )
  }

  var id: String { playableSession.segmentId }

  var durationText: String {
    let totalMilliseconds = playableSession.durationNanoseconds / 1_000_000
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds % 3_600_000) / 60_000
    let seconds = (totalMilliseconds % 60_000) / 1_000
    let milliseconds = totalMilliseconds % 1_000
    return String(
      format: "%02llu:%02llu:%02llu.%03llu",
      hours,
      minutes,
      seconds,
      milliseconds
    )
  }
}

/// The derived-transcript posture Rust projects for a saved conversation.
/// Chunk counts cover the runs still in progress; the state names only what
/// the store has committed.
struct RuntimeTranscriptPresentation: Equatable, Sendable {
  enum State: String, Equatable, Sendable {
    case none
    case running
    case final
    case partial
    case failed
    case cancelled
    case unknown
  }

  let state: State
  let documentAvailability: NativeDocumentAvailability
  let replacementResumable: Bool
  let selectedRevisionIds: [String]
  let documentVersion: String
  let attempt: NativeAttemptState
  let attemptFailure: String?
  let totalTracks: UInt32
  let finalTracks: UInt32
  let completedChunks: UInt32
  let totalChunks: UInt32
  let failureClass: String?

  init(native: NativeRuntimeTranscriptSnapshot?) {
    switch native?.state {
    case .none?: state = .none
    case .running?: state = .running
    case .final?: state = .final
    case .partial?: state = .partial
    case .failed?: state = .failed
    case .cancelled?: state = .cancelled
    case .unknown?, nil: state = .unknown
    }
    attempt = native?.attempt ?? .unknown
    documentAvailability = native?.document ?? .unavailable
    replacementResumable = native?.replacementResumable ?? false
    selectedRevisionIds = native?.selectedRevisionIds ?? []
    documentVersion = native?.documentVersion ?? "unavailable"
    attemptFailure = native?.attemptFailure
    totalTracks = native?.totalTracks ?? 0
    finalTracks = native?.finalTracks ?? 0
    completedChunks = native?.completedChunks ?? 0
    totalChunks = native?.totalChunks ?? 0
    failureClass = native?.failureClass
  }

  init(
    state: State, totalTracks: UInt32 = 1, finalTracks: UInt32 = 0, completedChunks: UInt32 = 0,
    totalChunks: UInt32 = 0, failureClass: String? = nil
  ) {
    self.state = state
    documentAvailability =
      state == .final
      ? .final : finalTracks > 0 ? .partial : state == .unknown ? .unavailable : .none
    replacementResumable = false
    selectedRevisionIds = []
    documentVersion = "fixture"
    attempt = state == .running ? .running : state == .failed ? .failed : .none
    attemptFailure = failureClass
    self.totalTracks = totalTracks
    self.finalTracks = finalTracks
    self.completedChunks = completedChunks
    self.totalChunks = totalChunks
    self.failureClass = failureClass
  }

  /// Whether the conversation has sealed audio a transcript can cover.
  var hasTranscribableAudio: Bool { totalTracks > 0 }

  /// Progress of the running runs as a fraction, when chunk counts exist.
  var runningFraction: Double? {
    guard attempt == .running, totalChunks > 0 else { return nil }
    return min(1, Double(completedChunks) / Double(totalChunks))
  }

  /// One short phrase for lists: what is true about the transcript now.
  var statusText: String {
    if documentAvailability == .partial {
      let document = "Transcript ready for \(finalTracks) of \(totalTracks) tracks"
      switch attempt {
      case .running: return document + " · transcription running"
      case .failed: return document + " · latest attempt failed"
      case .cancelled: return document + " · latest attempt cancelled"
      case .preempted: return document + " · transcription yielded to capture"
      case .unknown: return document + " · attempt status unavailable"
      case .none, .complete: return document
      }
    }
    return legacyStatusText
  }

  private var legacyStatusText: String {
    switch state {
    case .none: "No transcript yet"
    case .running:
      totalChunks > 0
        ? "Transcribing, \(completedChunks) of \(totalChunks) parts"
        : "Transcribing"
    case .final:
      switch attempt {
      case .running: "Transcript ready · replacement running"
      case .failed: "Transcript ready · replacement failed"
      case .cancelled: "Transcript ready · replacement cancelled"
      case .preempted: "Transcript ready · replacement yielded to capture"
      case .unknown: "Transcript ready · attempt status unavailable"
      case .none, .complete: "Transcript ready"
      }
    case .partial: "Transcript ready for \(finalTracks) of \(totalTracks) tracks"
    case .failed: "Transcript failed"
    case .cancelled:
      attempt == .preempted ? "Transcription yielded to capture" : "Transcription cancelled"
    case .unknown: "Transcript status unavailable"
    }
  }

  /// Scheduling wording adds intent to the durable document/attempt projection.
  /// It never changes availability or makes an eligibility decision.
  func line(for work: TranscriptionJobState?) -> (symbol: String, text: String) {
    let readable = documentAvailability == .final || documentAvailability == .partial
    func message(_ text: String) -> String { readable ? statusText + " · " + text : text }
    switch work {
    case .queued(let position, _):
      return ("clock", message(position == 1 ? "queued next" : "queued, \(position) in line"))
    case .running where attempt != .running:
      return ("ellipsis.circle", message("starting transcription"))
    case .failed where attempt != .failed:
      return ("exclamationmark.circle", message("latest request failed"))
    case .cancelled where attempt != .cancelled:
      return ("minus.circle", message("transcription cancelled"))
    case .preempted where attempt != .preempted:
      return ("pause.circle", message("transcription yielded to capture"))
    case .deferred:
      return ("clock", message("transcription deferred"))
    case .incomplete:
      return ("text.badge.plus", message("some tracks still need transcription"))
    default:
      let symbol =
        attempt == .running
        ? "ellipsis.circle"
        : attempt == .failed || attempt == .unknown ? "exclamationmark.circle" : "text.alignleft"
      return (symbol, statusText)
    }
  }

  /// Why the latest run ended without a transcript, in plain words. The
  /// recorded audio is never affected by any of these.
  static func failureText(_ failureClass: String?) -> String {
    switch failureClass {
    case "invalid_result", "stale_reconciliation":
      "The transcript could not be assembled from the finished parts. Retry rebuilds it from the parts that were kept."
    case "orphaned":
      "Transcription was interrupted before it finished. Retry continues from the parts that were kept."
    case "storage_error":
      "Transcript storage did not finish. Finished parts are kept for retry; the source audio is unchanged."
    case "cancelled":
      "Transcription was cancelled."
    case "model_unavailable":
      "The speech model is not installed."
    case "engine_error":
      "The speech engine stopped before it finished."
    case "resource_exhausted":
      "The Mac ran out of memory or disk space while transcribing."
    case "input_unavailable":
      "The recorded audio could not be read for transcription."
    default:
      "Transcription stopped before it finished."
    }
  }
}

struct RuntimeSessionPresentation: Equatable, Sendable, Identifiable {
  let sessionId: String
  let title: String
  let lifecycle: String
  let health: String
  let elapsedSeconds: UInt64
  let journalDurable: Bool
  let mediaFilesOpen: Bool
  let interruptionReason: String?
  let recovered: Bool
  let hasCaptureTimeline: Bool
  let captureRecoveryIsolated: Bool
  let sources: [RuntimeSourcePresentation]
  let playableMedia: RuntimePlayableMediaPresentation?
  let transcript: RuntimeTranscriptPresentation

  init(native: NativeRuntimeSessionSnapshot) {
    sessionId = native.sessionId
    title = native.title
    lifecycle = native.lifecycle
    health = native.health
    elapsedSeconds = native.elapsedSeconds
    journalDurable = native.journalDurable
    mediaFilesOpen = native.mediaFilesOpen
    interruptionReason = native.interruptionReason
    recovered = native.recovered
    hasCaptureTimeline = native.hasCaptureTimeline
    captureRecoveryIsolated = native.captureRecoveryIsolated
    sources = native.sources.map(RuntimeSourcePresentation.init(native:))
    playableMedia = native.playableMedia.map(RuntimePlayableMediaPresentation.init(native:))
    transcript = RuntimeTranscriptPresentation(native: native.transcript)
  }

  var id: String { sessionId }

  var deletionUnavailableReason: String? {
    if captureRecoveryIsolated {
      return "Move to Trash is unavailable until recovery can verify this capture's saved state."
    }
    guard lifecycle == "ready_for_review" || lifecycle == "interrupted" else {
      return "Finish the current capture before moving this conversation to Trash."
    }
    return nil
  }

  func hasVerifiedPreservedAudio(from recoveredSessions: [NativeRecoveredPlayableSession]) -> Bool {
    playableMedia?.isPlayable == true || !recoveredTracks(from: recoveredSessions).isEmpty
  }

  /// Imports have no required capture sources. Captures need Rust's saved
  /// clock calibration before transcripts or exports can use a shared timeline.
  var transcriptionUnavailableReason: String? {
    if captureRecoveryIsolated {
      return "This capture needs recovery before its audio can be transcribed or exported."
    }
    guard !hasCaptureTimeline, !sources.isEmpty else { return nil }
    return
      "This recording has no saved timing for its audio sources, so it cannot be transcribed or exported."
  }

  var isRecording: Bool {
    !captureRecoveryIsolated && lifecycle == "recording" && health == "healthy" && journalDurable
      && mediaFilesOpen
  }

  var isDegradedRecording: Bool {
    !captureRecoveryIsolated && lifecycle == "recording" && health == "degraded"
  }

  var needsAttention: Bool {
    captureRecoveryIsolated || lifecycle == "interrupted" || health == "degraded"
  }

  var pausedStatusSymbolName: String? {
    guard lifecycle == "paused", !needsAttention else { return nil }
    return SymbolResolver.pausedCaptureSymbolName
  }

  var captureStatusSymbolName: String {
    if captureRecoveryIsolated || lifecycle == "interrupted" || (recovered && needsAttention) {
      return SymbolResolver.captureSymbol(for: .recoveryRequired)
    }
    if needsAttention { return SymbolResolver.captureSymbol(for: .degraded) }
    if isRecording { return SymbolResolver.captureSymbol(for: .recording) }
    if let pausedStatusSymbolName { return pausedStatusSymbolName }
    let state: SymbolResolver.CaptureState =
      switch lifecycle {
      case "preparing", "recording", "finalizing": .starting
      case "ready_for_review": .ready
      default: .idle
      }
    return SymbolResolver.captureSymbol(for: state)
  }

  /// The sources capturing now, joined for speech: only what this session
  /// records, never a source the selection excluded.
  var capturingSourcesText: String {
    let names = sources.filter { $0.lifecycle == "capturing" }.map(\.name)
    return names.isEmpty ? "audio" : ListFormatter.localizedString(byJoining: names)
  }

  func recoveredTracks(
    from playableSessions: [NativeRecoveredPlayableSession]
  ) -> [RecoveredTrackPresentation] {
    guard recovered, playableMedia == nil else { return [] }

    return
      playableSessions
      .filter { $0.sessionId == sessionId }
      .map { RecoveredTrackPresentation(playableSession: $0) }
  }

  var statusText: String {
    if captureRecoveryIsolated { return "Capture recovery unavailable" }
    if recovered && needsAttention { return "Recovered partial recording" }
    if isDegradedRecording { return "Recording — degraded" }
    if let playableMedia { return playableMedia.statusText }
    return switch lifecycle {
    case "preparing": "Preparing durable recording…"
    case "recording": isRecording ? "Recording" : "Confirming recording…"
    case "paused": "Paused"
    case "finalizing": "Securing recording…"
    case "interrupted": "Recording interrupted"
    case "ready_for_review": recovered ? "Recovered and ready" : "Saved locally"
    default: lifecycle.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  var timerText: String {
    let hours = elapsedSeconds / 3_600
    let minutes = (elapsedSeconds % 3_600) / 60
    let seconds = elapsedSeconds % 60
    return String(format: "%02llu:%02llu:%02llu", hours, minutes, seconds)
  }

  var interruptionText: String? {
    if captureRecoveryIsolated {
      return
        "Recovery could not verify this capture's evidence. Last accepted state: \(lifecycle.replacingOccurrences(of: "_", with: " "))."
    }
    guard let interruptionReason else { return nil }
    return switch interruptionReason {
    case "capture_start_failed": "Capture could not start; durable recovery state was preserved."
    case "capture_failed": "A capture source failed; durable recovery state was preserved."
    case "first_sample_rejected": "First-sample evidence was rejected; recording was not claimed."
    case "stop_without_durable_sample": "A required source had no durable final sample."
    case "segment_seal_failed": "Audio could not be sealed; recovery state was preserved."
    case "permission_revoked":
      "Capture permission was withdrawn; the audio recorded before that was preserved."
    default: "Capture was interrupted; recovery state was preserved."
    }
  }

  var recoveryText: String {
    if recovered && needsAttention { return "Recovered partial recording" }
    if recovered { return "Recovered" }
    if lifecycle == "interrupted" { return "Recovery required" }
    if lifecycle == "ready_for_review" { return "Ready for review" }
    return "Not required"
  }
}

enum SessionTimerBehavior: String, Equatable, Sendable {
  case hidden
  case advancing
  case frozen
}

struct SourcePresentation: Equatable, Sendable {
  let id: String
  let name: String
  let activity: String
  let health: String
  let healthDetail: String?
  let permission: String
  let permissionRecoveryHint: String?
}

struct SurfaceTruth: Equatable, Sendable {
  let label: String
  let timerText: String?
  let accessibilityValue: String
  let symbolName: String?
}

struct SessionPresentation: Equatable, Sendable {
  let fixtureName: String
  let sessionID: String
  let title: String
  let lifecycle: String
  let presentation: String
  let health: String
  let elapsedSeconds: UInt64
  let timerBehavior: SessionTimerBehavior
  let timerText: String?
  let label: String
  let primarySymbol: String?
  let fallbackSymbol: String?
  let accessibilityValue: String
  let announcement: String?
  let journalDurable: Bool
  let mediaFilesOpen: Bool
  let mediaSafe: Bool
  let recoveryStatus: String
  let recoverySummary: String?
  let sources: [SourcePresentation]

  init(native: NativeSessionSnapshot) {
    fixtureName = native.fixture
    sessionID = native.sessionId
    title = native.title
    lifecycle = native.lifecycle
    presentation = native.presentation
    health = native.health
    elapsedSeconds = native.elapsedSeconds
    timerBehavior = SessionTimerBehavior(rawValue: native.timerBehavior) ?? .hidden
    timerText = native.timerText
    label = native.label
    primarySymbol = native.primarySymbol
    fallbackSymbol = native.fallbackSymbol
    accessibilityValue = native.accessibilityValue
    announcement = native.announcement
    journalDurable = native.journalDurable
    mediaFilesOpen = native.mediaFilesOpen
    mediaSafe = native.mediaSafe
    recoveryStatus = native.recoveryStatus
    recoverySummary = native.recoverySummary
    sources = native.sources.map {
      SourcePresentation(
        id: $0.id,
        name: $0.name,
        activity: $0.activity,
        health: $0.health,
        healthDetail: $0.healthDetail,
        permission: $0.permission,
        permissionRecoveryHint: $0.permissionRecoveryHint
      )
    }
  }

  var isDurableRecording: Bool {
    lifecycle == "recording" && journalDurable && mediaFilesOpen
  }

  var isWarning: Bool {
    presentation == "recording_degraded" || presentation == "permission_revoked"
      || presentation == "recovery_required"
  }

  var resolvedSymbolName: String? {
    SymbolResolver.resolve(primary: primarySymbol, fallback: fallbackSymbol)
  }

  var surfaceTruth: SurfaceTruth {
    SurfaceTruth(
      label: label,
      timerText: timerText,
      accessibilityValue: accessibilityValue,
      symbolName: resolvedSymbolName
    )
  }

  var statusText: String {
    switch presentation {
    case "idle": "Idle"
    case "ready": "Ready"
    case "starting": "Starting…"
    case "recording": "Recording"
    case "paused": "Paused"
    case "finalizing": "Finalizing"
    case "recording_degraded": "Recording — degraded"
    case "permission_revoked": "Permission revoked"
    case "recovery_required": "Recovery required"
    case "complete": "Complete"
    default: label
    }
  }

  var nativeFixture: NativeFixture {
    switch fixtureName {
    case "ready": .ready
    case "starting": .starting
    case "recording": .recording
    case "paused": .paused
    case "finalizing": .finalizing
    case "recording_degraded": .recordingDegraded
    case "permission_revoked": .permissionRevoked
    case "recovery_required": .recoveryRequired
    case "complete": .complete
    default: .idle
    }
  }
}

enum FixtureCatalog {
  static func load() -> [SessionPresentation] {
    nativeFixtureCatalog().map(SessionPresentation.init(native:))
  }
}
