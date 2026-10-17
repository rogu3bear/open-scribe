import Foundation
import Security

struct DiagnosticEvent: Equatable, Sendable, Identifiable {
  let id: UUID
  let recordedAt: Date
  let category: String
  let message: String

  init(category: String, message: String, recordedAt: Date = Date(), id: UUID = UUID()) {
    self.id = id
    self.recordedAt = recordedAt
    self.category = category
    self.message = message
  }
}

/// A bounded, process-local record of privacy-safe log lines. It never leaves
/// the Mac and never stores transcript text, names, or file paths.
final class DiagnosticJournal: @unchecked Sendable {
  static let shared = DiagnosticJournal()
  static let limit = 80

  private let lock = NSLock()
  private var events: [DiagnosticEvent] = []

  func record(category: String, message: String) {
    let safe = DiagnosticPrivacy.sanitize(category: category, message: message)
    lock.lock()
    events.append(DiagnosticEvent(category: safe.category, message: safe.message))
    if events.count > Self.limit {
      events.removeFirst(events.count - Self.limit)
    }
    let snapshot = events
    lock.unlock()
    // Settings observes this copy. Publishing on the next main-actor turn
    // keeps a note recorded during a view update from redrawing that update.
    DispatchQueue.main.async {
      DiagnosticLog.shared.replace(snapshot)
    }
  }

  func recent() -> [DiagnosticEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func resetForTest() {
    lock.lock()
    events.removeAll()
    lock.unlock()
  }
}

enum DiagnosticPrivacy {
  static let maximumMessageLength = 240
  static let redactedMessage = "redacted=private_or_unbounded"

  private static let categories: Set<String> = [
    "Scenes", "Commands", "CaptureProof", "RecoveryProof", "Launch", "Library", "Performance",
    "redacted",
  ]
  private static let keys: Set<String> = [
    "scene", "rust_core_version", "fixture", "lifecycle", "presentation", "journal_durable",
    "media_files_open", "runtime_session", "command", "stage", "detail", "source", "generation",
    "sequence", "event", "callbacks", "written_frames", "last_progress_uptime_ns", "rust_state",
    "visible_state", "single_instance_failure", "microphone", "screen_capture", "operation",
    "milliseconds", "from", "to", "session", "code", "current", "saved", "count", "ready",
    "model", "result", "tracks", "segments", "phase", "redacted",
  ]
  // This is a log vocabulary, not a substring blacklist. Free text and unknown
  // upstream values have no diagnostic standing, even when short and path-free.
  private static let words: Set<String> = [
    "none", "unknown", "redacted", "private_or_unbounded", "true", "false", "admitted",
    "primary", "menu-bar", "live-session", "settings", "quit", "open-primary",
    "export-diagnostics", "export-diagnostics-failed", "microphone", "system_audio",
    "application_audio", "active", "inactive", "ended", "required", "healthy", "degraded",
    "idle", "requestingPermission", "preparing", "starting", "recording", "capturing", "pausing",
    "paused", "resuming", "stopping", "saved", "failed", "finalizing", "ready_for_review",
    "interrupted", "deleted", "progress", "route_interrupted", "route_recovered", "writer_failed",
    "notDetermined", "restricted", "denied", "authorized", "not_authorized", "unavailable",
    "phase", "mixdown", "verified", "requested", "explicit-command", "first-sample-durable",
    "capture-proof-refused", "media-recovery", "capture-requested", "capture-durable",
    "awaiting-external-kill", "recovery-empty", "recovery-failed", "no-playable-session",
    "capture-failed", "recovered", "playback-not-admitted", "playback-wait-cancelled",
    "playback-open-failed",
    "playback-open-superseded", "playback-open-timeout", "playback-opened",
    "playback-open-state-unavailable", "native-audio-engine", "playback-failed", "playback-started",
    "playback-stopped", "playback-requested", "scan-started", "launch", "scan-finished",
    "scan-cancelled",
    "scan-rejected",
    "scan-failed", "scanning", "available", "invalid_evidence", "snapshot", "snapshot-failed",
    "rename", "renamed", "refused", "declare", "speech-catalog", "speech-install", "installed",
    "readiness_unavailable", "rejected", "transcription", "started", "committed", "cancelled",
    "ModelNotInstalled", "ModelRejected", "ModelReadiness", "NoTranscribableAudio",
    "DecodedAudioRejected", "Cancelled", "CapturePreempted", "Deferred", "TranscriptionFailed",
    "StorageFailure", "alreadyRunning", "library_snapshot", "launch_recovery",
    "launch_recovery_main",
    "playback_copy", "playback_copy_main", "capture-start-or-setup", "first-sample-evidence",
    "recording-authority",
    "storage-observation-failed", "system-audio-unavailable", "segment-seal", "stop-without-sample",
  ]

  static func sanitize(category: String, message: String) -> (category: String, message: String) {
    let safeCategory = categories.contains(category) ? category : "redacted"
    guard isBounded(message) else { return (safeCategory, redactedMessage) }
    let safeMessage = message.split(separator: " ").map { fragment in
      sanitizeFragment(String(fragment), depth: 0)
    }.joined(separator: " ")
    return (safeCategory, safeMessage)
  }

  static func isPrivate(_ text: String) -> Bool {
    !isBounded(text)
      || text.split(separator: " ").contains {
        sanitizeFragment(String($0), depth: 0) != $0
      }
  }

  /// A machine field, never arbitrary text from a session, file or Error.
  static func token(_ text: String) -> String {
    isBounded(text) && isValue(text) ? text : "redacted"
  }

  static func state(_ value: String) -> String {
    words.contains(value) ? value : "redacted"
  }

  static func session(_ value: String) -> String {
    UUID(uuidString: value) == nil ? "redacted" : value
  }

  static func model(_ value: String, file: Bool = false) -> String {
    if file && (!value.hasPrefix("ggml-") || !value.hasSuffix(".bin")) { return "redacted" }
    let name = file ? "whisper-" + String(value.dropFirst(5).dropLast(4)) : value
    guard name.hasPrefix("whisper-") else { return "redacted" }
    return matches(name, "^whisper-(tiny|base|small|medium|large)(\\.en)?(-q[0-9]+_[0-9]+)?$")
      ? value : "redacted"
  }

  fileprivate static func metadata(_ value: String, pattern: String) -> String {
    isBounded(value) && matches(value, pattern) ? value : "redacted"
  }

  private static func isBounded(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= maximumMessageLength
      && !text.contains("/") && !text.contains("\\") && !text.contains("..")
      && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func sanitizeFragment(_ fragment: String, depth: Int) -> String {
    guard depth <= 2 else { return "redacted" }
    guard let separator = fragment.firstIndex(of: "=") else {
      return state(fragment)
    }
    let key = String(fragment[..<separator])
    guard keys.contains(key) else { return "redacted" }
    let value = String(fragment[fragment.index(after: separator)...])
    let safeValue: String
    switch key {
    case "detail" where value.contains("="):
      safeValue = sanitizeFragment(value, depth: depth + 1)
    case "session", "current", "runtime_session":
      safeValue = value == "none" || value == "redacted" ? value : session(value)
    case "model": safeValue = model(value)
    case "generation", "sequence", "callbacks", "written_frames", "last_progress_uptime_ns",
      "milliseconds", "saved", "count", "ready", "tracks", "segments":
      safeValue = unsigned(value) ? value : "redacted"
    case "journal_durable", "media_files_open":
      safeValue = value == "true" || value == "false" ? value : "redacted"
    case "rust_core_version":
      safeValue = metadata(value, pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    case "single_instance_failure":
      safeValue = value == "alreadyRunning" || validOpenFailure(value) ? value : "redacted"
    case "detail" where value.hasPrefix("bytes-"):
      safeValue = isValue(value) ? value : "redacted"
    default: safeValue = state(value)
    }
    return key + "=" + safeValue
  }

  private static func isValue(_ value: String) -> Bool {
    if words.contains(value) || unsigned(value) { return true }
    if value.utf8.count == 36 && UUID(uuidString: value) != nil { return true }
    if value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
      let parts = value.split(separator: ".", omittingEmptySubsequences: false)
      if parts.count == 3 && parts.allSatisfy({ $0.count <= 8 && unsigned(String($0)) }) {
        return true
      }
    }
    if value.hasPrefix("whisper-") { return model(value) != "redacted" }
    if value.hasPrefix("bytes-") {
      let parts = value.split(separator: "-")
      return parts.count == 4 && parts[2] == "frames"
        && unsigned(String(parts[1])) && unsigned(String(parts[3]))
    }
    return validOpenFailure(value)
  }

  private static func validOpenFailure(_ value: String) -> Bool {
    value.hasPrefix("cannotOpen(") && value.hasSuffix(")")
      && unsigned(String(value.dropFirst(11).dropLast()))
  }

  private static func unsigned(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
      && UInt64(value) != nil
  }

  private static func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }
}

/// The journal lines Settings is currently showing. `replace` runs on the main
/// thread; the journal itself stays lock-protected for capture callbacks.
final class DiagnosticLog: ObservableObject, @unchecked Sendable {
  static let shared = DiagnosticLog()
  @Published private(set) var events: [DiagnosticEvent] = []

  func replace(_ events: [DiagnosticEvent]) {
    self.events = events
  }
}

enum DiagnosticTiming {
  static let stallMilliseconds = 80

  static func milliseconds(since started: ContinuousClock.Instant) -> Int {
    let parts = started.duration(to: .now).components
    let value = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    return Int(clamping: value)
  }

  static func note(_ operation: String, milliseconds: Int) {
    guard milliseconds >= stallMilliseconds else { return }
    AppTelemetry.performanceStall(operation: operation, milliseconds: milliseconds)
  }
}

enum DiagnosticsSignature {
  /// Coarse signature state for a local diagnostics export. The executable
  /// path is never included.
  static func current() -> String {
    guard let executable = Bundle.main.executableURL else { return "unknown" }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
      let code
    else { return "unsigned" }
    var information: CFDictionary?
    let copied = SecCodeCopySigningInformation(
      code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    guard copied == errSecSuccess,
      let values = information as NSDictionary?
    else { return "unsigned" }
    let team = values[kSecCodeInfoTeamIdentifier as String] as? String
    if let team, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) {
      return "signed team=\(team)"
    }
    let identifier = values[kSecCodeInfoIdentifier as String] as? String
    if identifier?.isEmpty != false { return "unsigned" }
    return "ad_hoc"
  }
}

enum DiagnosticsReport {
  static let maximumListedSessions = 40
  static let maximumListedModels = 40
  static let maximumListedEvents = 80

  struct ModelLine: Equatable, Sendable {
    var modelId: String
    var fileName: String
    var installed: Bool
  }

  struct SessionLine: Equatable, Sendable {
    var sessionId: String
    var lifecycle: String
    var health: String
    var recovered: Bool
    var journalDurable: Bool
    var mediaFilesOpen: Bool
  }

  static func text(
    product: String,
    version: String,
    build: String,
    operatingSystem: String,
    architecture: String,
    bundleIdentifier: String,
    microphone: String,
    screenCapture: String,
    signature: String,
    recoveryPhase: String,
    recoveredCount: Int,
    sessions: [SessionLine],
    models: [ModelLine],
    events: [DiagnosticEvent]
  ) -> String {
    var lines = [
      "Open Scribe diagnostics",
      "product=\(product == "Open Scribe" ? product : "redacted")",
      "version=\(DiagnosticPrivacy.metadata(version, pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$"))",
      "build=\(DiagnosticPrivacy.metadata(build, pattern: "^[0-9]+$"))",
      "os=\(DiagnosticPrivacy.metadata(operatingSystem, pattern: "^Version [0-9]+(?:\\.[0-9]+){1,2}(?: \\(Build [A-Za-z0-9]+\\))?$"))",
      "arch=\(["arm64", "x86_64", "unknown"].contains(architecture) ? architecture : "redacted")",
      "bundle=\(DiagnosticPrivacy.metadata(bundleIdentifier, pattern: "^app\\.open-scribe(?:\\.dev(?:\\.verification)?)?$"))",
      "microphone=\(DiagnosticPrivacy.state(microphone))",
      "screen_capture=\(DiagnosticPrivacy.state(screenCapture))",
      "signature=\(DiagnosticPrivacy.metadata(signature, pattern: "^(unsigned|ad_hoc|unknown|signed team=[A-Z0-9]{10})$"))",
      "recovery_phase=\(DiagnosticPrivacy.state(recoveryPhase))",
      "recovered_count=\(recoveredCount)",
      "models_installed=\(models.filter(\.installed).count)",
      "models_catalog=\(models.count)",
      "sessions=\(sessions.count)",
    ]
    let listed = sessions.prefix(maximumListedSessions)
    if sessions.count > listed.count {
      lines.append("sessions_omitted=\(sessions.count - listed.count)")
    }
    for session in listed {
      lines.append(
        "session id=\(DiagnosticPrivacy.session(session.sessionId)) lifecycle=\(DiagnosticPrivacy.state(session.lifecycle)) health=\(DiagnosticPrivacy.state(session.health)) recovered=\(session.recovered) journal_durable=\(session.journalDurable) media_files_open=\(session.mediaFilesOpen)"
      )
    }
    for model in models.prefix(maximumListedModels) {
      lines.append(
        "model id=\(DiagnosticPrivacy.model(model.modelId)) installed=\(model.installed) file=\(DiagnosticPrivacy.model(model.fileName, file: true))"
      )
    }
    if models.count > maximumListedModels {
      lines.append("models_omitted=\(models.count - maximumListedModels)")
    }
    let listedEvents = events.suffix(maximumListedEvents)
    lines.append("events=\(listedEvents.count)")
    if events.count > listedEvents.count {
      lines.append("events_omitted=\(events.count - listedEvents.count)")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for event in listedEvents {
      let safe = DiagnosticPrivacy.sanitize(category: event.category, message: event.message)
      lines.append(
        "\(formatter.string(from: event.recordedAt)) \(safe.category) \(safe.message)")
    }
    lines.append(
      "note=session titles, transcript text, and file paths are omitted")
    return lines.joined(separator: "\n") + "\n"
  }

}
