import AppKit

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
