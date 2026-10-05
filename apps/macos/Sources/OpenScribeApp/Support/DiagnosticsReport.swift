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

  static func sanitize(category: String, message: String) -> (category: String, message: String) {
    let safeCategory = isPrivate(category) ? "redacted" : category
    let safeMessage = isPrivate(message) ? "redacted=private_or_unbounded" : message
    return (safeCategory, safeMessage)
  }

  static func isPrivate(_ text: String) -> Bool {
    if text.isEmpty || text.count > maximumMessageLength { return true }
    if text.contains("/") || text.contains("\\") || text.contains("..") { return true }
    let lowered = text.lowercased()
    if lowered.contains("file:") || lowered.contains("transcript=") { return true }
    return text.unicodeScalars.contains { $0.value < 32 }
  }

  /// A single log field. A private value becomes the word `redacted` so the
  /// rest of the line can still be kept.
  static func token(_ text: String) -> String {
    isPrivate(text) ? "redacted" : text
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
      "product=\(product)",
      "version=\(version)",
      "build=\(build)",
      "os=\(operatingSystem)",
      "arch=\(architecture)",
      "bundle=\(bundleIdentifier)",
      "microphone=\(microphone)",
      "screen_capture=\(screenCapture)",
      "signature=\(signature)",
      "recovery_phase=\(recoveryPhase)",
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
        "session id=\(field(session.sessionId)) lifecycle=\(field(session.lifecycle)) health=\(field(session.health)) recovered=\(session.recovered) journal_durable=\(session.journalDurable) media_files_open=\(session.mediaFilesOpen)"
      )
    }
    for model in models {
      lines.append(
        "model id=\(model.modelId) installed=\(model.installed) file=\(model.fileName)")
    }
    lines.append("events=\(events.count)")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for event in events {
      lines.append(
        "\(formatter.string(from: event.recordedAt)) \(event.category) \(event.message)")
    }
    lines.append(
      "note=session titles, transcript text, and file paths are omitted")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func field(_ value: String) -> String {
    DiagnosticPrivacy.isPrivate(value) ? "redacted" : value
  }
}
