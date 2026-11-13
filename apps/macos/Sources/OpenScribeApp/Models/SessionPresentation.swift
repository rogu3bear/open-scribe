import AppKit

struct RuntimeSourcePresentation: Equatable, Sendable {
  let kind: NativeMediaSourceKind
  let name: String
  let lifecycle: NativeSourceLifecycle

  init(native: NativeRuntimeSourceSnapshot) {
    kind = native.kind
    name = native.displayName
    lifecycle = native.lifecycle
  }

  init(kind: NativeMediaSourceKind, name: String, lifecycle: NativeSourceLifecycle) {
    self.kind = kind
    self.name = name
    self.lifecycle = lifecycle
  }

  var stateText: String {
    switch lifecycle {
    case .required: "Waiting"
    case .opening: "Opening"
    case .open: "Ready"
    case .capturing: "Capturing"
    case .failed: "Failed"
    case .sealed: "Saved"
    case .unavailable: "Unavailable"
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
  let availability: NativePlayableMediaAvailability
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
    availability == .available && sampleCount > 0 && byteLength > 0
  }

  var durationText: String { DurationText.length(nanoseconds: durationNanoseconds) }

  var statusText: String {
    switch availability {
    case .available: "Ready to play"
    case .unavailable: "Audio file missing"
    case .corrupt: "Audio file damaged"
    }
  }
}

struct RecoveredTrackPresentation: Identifiable {
  let playableSession: NativeRecoveredPlayableSession

  var source: RuntimeSourcePresentation {
    RuntimeSourcePresentation(
      kind: playableSession.sourceKind,
      name: playableSession.sourceDisplayName,
      lifecycle: .sealed
    )
  }

  var id: String { playableSession.segmentId }

  var durationText: String {
    DurationText.preciseLength(nanoseconds: playableSession.durationNanoseconds)
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
  let attemptFailure: NativeTranscriptionFailureClass?
  let totalTracks: UInt32
  let finalTracks: UInt32
  let completedChunks: UInt32
  let totalChunks: UInt32
  let failureClass: NativeTranscriptionFailureClass?
  /// Live Draft windows saved while recording; readable before any Final.
  let draftWindows: UInt32

  var hasDraftText: Bool { draftWindows > 0 }

  init(native: NativeRuntimeTranscriptSnapshot?) {
    draftWindows = native?.draftWindows ?? 0
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
    totalChunks: UInt32 = 0, failureClass: NativeTranscriptionFailureClass? = nil
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
    draftWindows = 0
  }

  /// Whether the conversation has sealed audio a transcript can cover.
  var hasTranscribableAudio: Bool { totalTracks > 0 }

  /// Progress of the running runs as a fraction, when chunk counts exist.
  var runningFraction: Double? {
    guard attempt == .running, totalChunks > 0 else { return nil }
    return min(1, Double(completedChunks) / Double(totalChunks))
  }

  /// One short phrase for lists: what is true about the transcript now.
  var statusText: String { TranscriptStatusPresentation.summary(self) }

  /// The list phrase with the scheduler's intent added.
  func line(for work: TranscriptionJobState?) -> (symbol: String, text: String) {
    TranscriptStatusPresentation.line(self, job: work)
  }
}

struct RuntimeSessionPresentation: Equatable, Sendable, Identifiable {
  let sessionId: String
  let title: String
  /// The title a reader sees: a person's, else a suggestion, else the placeholder.
  let displayTitle: String
  let titleSource: NativeTitleSource
  /// The capture time Rust read from a placeholder display title.
  let placeholderAtMs: Int64?
  /// When the conversation was added to the library; nil from older producers.
  let createdAt: Date?
  let lifecycle: NativeSessionLifecycle
  let health: NativeSessionHealth
  let elapsedSeconds: UInt64
  let journalDurable: Bool
  let mediaFilesOpen: Bool
  let interruptionReason: NativeSessionInterruptionReason?
  let recovered: Bool
  let hasCaptureTimeline: Bool
  let captureRecoveryIsolated: Bool
  /// Rust found audio in this session: accepted samples or recovered media.
  let preservedAudio: Bool
  /// Rust's Trash rule for this session's lifecycle and audio.
  let canMoveToTrash: Bool
  let sources: [RuntimeSourcePresentation]
  let playableMedia: RuntimePlayableMediaPresentation?
  let transcript: RuntimeTranscriptPresentation

  init(native: NativeRuntimeSessionSnapshot) {
    sessionId = native.sessionId
    title = native.title
    displayTitle = native.displayTitle.isEmpty ? native.title : native.displayTitle
    titleSource = native.titleSource
    placeholderAtMs = native.placeholderAtMs
    createdAt =
      native.createdAtMs > 0
      ? Date(timeIntervalSince1970: Double(native.createdAtMs) / 1_000) : nil
    lifecycle = native.lifecycle
    health = native.health
    elapsedSeconds = native.elapsedSeconds
    journalDurable = native.journalDurable
    mediaFilesOpen = native.mediaFilesOpen
    interruptionReason = native.interruptionReason
    recovered = native.recovered
    hasCaptureTimeline = native.hasCaptureTimeline
    captureRecoveryIsolated = native.captureRecoveryIsolated
    preservedAudio = native.preservedAudio
    canMoveToTrash = native.canMoveToTrash
    sources = native.sources.map(RuntimeSourcePresentation.init(native:))
    playableMedia = native.playableMedia.map(RuntimePlayableMediaPresentation.init(native:))
    transcript = RuntimeTranscriptPresentation(native: native.transcript)
  }

  var id: String { sessionId }

  /// A recording that stopped before any audio was saved. It has nothing to
  /// review, so the library folds it into one quiet row.
  var didNotRecord: Bool {
    (lifecycle == .interrupted || captureRecoveryIsolated) && !preservedAudio && !recovered
  }

  func hasVerifiedPreservedAudio(from recoveredSessions: [NativeRecoveredPlayableSession]) -> Bool {
    playableMedia?.isPlayable == true || !recoveredTracks(from: recoveredSessions).isEmpty
  }

  /// Imports have no required capture sources. Captures need Rust's saved
  /// clock calibration before transcripts or exports can use a shared timeline.
  var transcriptionUnavailableReason: String? {
    if captureRecoveryIsolated {
      return "This recording's audio couldn't be opened, so it can't be transcribed or exported."
    }
    guard !hasCaptureTimeline, !sources.isEmpty else { return nil }
    return
      "This recording has no saved timing for its audio sources, so it can't be transcribed or exported."
  }

  var isRecording: Bool {
    !captureRecoveryIsolated && lifecycle == .recording && health == .healthy && journalDurable
      && mediaFilesOpen
  }

  var isDegradedRecording: Bool {
    !captureRecoveryIsolated && lifecycle == .recording && health == .degraded
  }

  var needsAttention: Bool {
    captureRecoveryIsolated || lifecycle == .interrupted || health == .degraded
  }

  var pausedStatusSymbolName: String? {
    guard lifecycle == .paused, !needsAttention else { return nil }
    return SymbolResolver.pausedCaptureSymbolName
  }

  var captureStatus: CaptureStatusPresentation { CaptureStatusPresentation(session: self) }
  var captureStatusSymbolName: String { captureStatus.symbolName }
  var statusText: String { captureStatus.text }
  /// What happened to a conversation that needs attention, in one sentence.
  var interruptionText: String? { CaptureStatusPresentation.attentionText(for: self) }

  /// The running clock of an open capture.
  var timerText: String { DurationText.clock(seconds: elapsedSeconds) }

  /// The conversation's length in words; none for an attempt that never recorded.
  var lengthText: String? {
    didNotRecord || elapsedSeconds == 0 ? nil : DurationText.length(seconds: elapsedSeconds)
  }

  /// The sources capturing now, joined for speech: only what this session
  /// records, never a source the selection excluded.
  var capturingSourcesText: String {
    let names = sources.filter { $0.lifecycle == .capturing }.map(\.name)
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

  var recoveryText: String {
    if recovered && needsAttention { return "Recovered partial recording" }
    if recovered { return "Recovered" }
    if lifecycle == .interrupted { return "Recovery required" }
    if lifecycle == .readyForReview { return "Ready for review" }
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

  var resolvedSymbolName: String? {
    SymbolResolver.resolve(primary: primarySymbol, fallback: fallbackSymbol)
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
