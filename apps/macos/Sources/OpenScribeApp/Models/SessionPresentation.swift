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
  let sources: [RuntimeSourcePresentation]
  let playableMedia: RuntimePlayableMediaPresentation?

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
    sources = native.sources.map(RuntimeSourcePresentation.init(native:))
    playableMedia = native.playableMedia.map(RuntimePlayableMediaPresentation.init(native:))
  }

  var id: String { sessionId }

  var isRecording: Bool {
    lifecycle == "recording" && health == "healthy" && journalDurable && mediaFilesOpen
  }

  var isDegradedRecording: Bool {
    lifecycle == "recording" && health == "degraded"
  }

  var needsAttention: Bool {
    lifecycle == "interrupted" || health == "degraded"
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
    guard let interruptionReason else { return nil }
    return switch interruptionReason {
    case "capture_start_failed": "Capture could not start; durable recovery state was preserved."
    case "capture_failed": "A capture source failed; durable recovery state was preserved."
    case "first_sample_rejected": "First-sample evidence was rejected; recording was not claimed."
    case "stop_without_durable_sample": "A required source had no durable final sample."
    case "segment_seal_failed": "Audio could not be sealed; recovery state was preserved."
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
