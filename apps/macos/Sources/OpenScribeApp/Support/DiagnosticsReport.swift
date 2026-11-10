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
    CrashReportContent.observe(message)
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

/// The only crash annotation this process keeps. Raw notes are classified
/// here before they can be repeated. A refusal stores a fixed marker, never
/// the transcript, credential, path, prompt, name, or screen text offered.
private final class CrashReportState: @unchecked Sendable {
  let lock = NSLock()
  var annotation = "none"
  var refusals: [String] = []
}

enum CrashReportContent {
  private static let state = CrashReportState()

  static func resetForTest() {
    state.lock.lock()
    state.annotation = "none"
    state.refusals.removeAll()
    state.lock.unlock()
  }

  static func observe(_ proposed: String) {
    let assessment = assess(proposed)
    state.lock.lock()
    if assessment.refusals.isEmpty {
      if assessment.keepsAnnotation {
        state.annotation = assessment.annotation
      }
    } else {
      state.annotation = DiagnosticPrivacy.redactedMessage
      for item in assessment.refusals where !state.refusals.contains(item) {
        state.refusals.append(item)
      }
    }
    state.lock.unlock()
  }

  static func snapshot() -> (annotation: String, refusals: String) {
    state.lock.lock()
    defer { state.lock.unlock() }
    let refused = state.refusals.isEmpty ? "none" : state.refusals.joined(separator: ",")
    return (state.annotation, refused)
  }

  private struct Assessment {
    var annotation: String
    var refusals: [String]
    var keepsAnnotation: Bool
  }

  private static func assess(_ proposed: String) -> Assessment {
    if DiagnosticPrivacy.isCategory(proposed) {
      return Assessment(annotation: proposed, refusals: [], keepsAnnotation: false)
    }
    var refusals: [String] = []
    if proposed.contains("/") || proposed.contains("\\") || proposed.contains("~")
      || proposed.contains("..")
    {
      refusals.append("private_path")
    }
    let lower = proposed.lowercased()
    if lower.contains("sk-") || lower.contains("bearer ") || lower.contains("api_key")
      || lower.contains("api-key") || lower.contains("apikey")
      || lower.range(of: #"password\s*="#, options: .regularExpression) != nil
    {
      refusals.append("credential")
    }
    if lower.contains("ignore previous") || lower.contains("system prompt")
      || lower.contains("prompt=")
    {
      refusals.append("prompt")
    }
    if lower.contains("participant=") {
      refusals.append("participant")
    }
    if lower.contains("ocr=") || lower.contains("screenshot") || lower.contains("window content")
    {
      refusals.append("screen")
    }
    let sanitized = DiagnosticPrivacy.sanitize(category: "RecoveryProof", message: proposed).message
    let unchanged = sanitized == proposed
    let sessionIdentifier = DiagnosticPrivacy.session(proposed) == proposed
    if !unchanged && !sessionIdentifier
      && (refusals.isEmpty || proposed.split(separator: " ").count >= 3)
    {
      refusals.append("transcript")
    }
    let keeps = refusals.isEmpty && unchanged
    return Assessment(
      annotation: keeps ? sanitized : DiagnosticPrivacy.redactedMessage,
      refusals: refusals,
      keepsAnnotation: keeps
    )
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
    for session in sessions {
      CrashReportContent.observe(session.sessionId)
    }
    for event in events {
      CrashReportContent.observe(event.category)
      CrashReportContent.observe(event.message)
    }
    let crash = CrashReportContent.snapshot()
    lines.append("crash_report=content_free")
    lines.append("crash_report_refused=\(crash.refusals)")
    lines.append("crash_annotation=\(crash.annotation)")
    lines.append(
      "note=session titles, transcript text, and file paths are omitted")
    return lines.joined(separator: "\n") + "\n"
  }

}
