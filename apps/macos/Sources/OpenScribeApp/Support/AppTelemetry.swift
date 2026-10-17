import Foundation
import OSLog

struct CaptureSourceHealthTelemetryRecord: Equatable, Sendable {
  let observation: MicrophoneSourceHealthObservation
  let rustSourceState: String
  let visibleState: String

  var privacySafeMessage: String {
    let message = [
      "source=microphone",
      "generation=\(observation.identity.writerGeneration)",
      "sequence=\(observation.sequence)",
      "event=\(observation.event.rawValue)",
      "callbacks=\(observation.callbackCount)",
      "written_frames=\(observation.successfullyWrittenFrameCount)",
      "last_progress_uptime_ns=\(observation.lastProgressMonotonicNanoseconds)",
      "rust_state=\(rustSourceState)",
      "visible_state=\(visibleState)",
    ].joined(separator: " ")
    return DiagnosticPrivacy.sanitize(category: "CaptureProof", message: message).message
  }
}

enum AppTelemetry {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "app.open-scribe.dev"
  private static let scenes = Logger(subsystem: subsystem, category: "Scenes")
  private static let commands = Logger(subsystem: subsystem, category: "Commands")
  private static let capture = Logger(subsystem: subsystem, category: "CaptureProof")
  private static let recovery = Logger(subsystem: subsystem, category: "RecoveryProof")
  private static let launch = Logger(subsystem: subsystem, category: "Launch")
  private static let library = Logger(subsystem: subsystem, category: "Library")
  private static let performance = Logger(subsystem: subsystem, category: "Performance")
  static let signposter = OSSignposter(subsystem: subsystem, category: "Performance")

  /// Both sinks consume the same validated record. No raw Error, path or
  /// caller-supplied message reaches the public unified log first.
  private static func emit(
    _ logger: Logger, category: String, message: String,
    failure: Bool = false, journal: Bool = true
  ) {
    let safe = DiagnosticPrivacy.sanitize(category: category, message: message)
    if failure {
      logger.error("\(safe.message, privacy: .public)")
    } else {
      logger.info("\(safe.message, privacy: .public)")
    }
    if journal { DiagnosticJournal.shared.record(category: safe.category, message: safe.message) }
  }

  static func sceneAppeared(_ scene: String, status: AppStatus) {
    emit(
      scenes, category: "Scenes",
      message: "scene=\(scene) rust_core_version=\(status.coreVersion)")
  }

  static func sceneAppeared(_ scene: String, snapshot: SessionPresentation) {
    emit(
      scenes, category: "Scenes",
      message:
        "scene=\(scene) fixture=\(snapshot.fixtureName) lifecycle=\(snapshot.lifecycle) presentation=\(snapshot.presentation) journal_durable=\(snapshot.journalDurable) media_files_open=\(snapshot.mediaFilesOpen)"
    )
  }

  static func runtimeSceneAppeared(_ scene: String, session: RuntimeSessionPresentation?) {
    emit(
      scenes, category: "Scenes",
      message:
        "scene=\(scene) runtime_session=\(session?.sessionId ?? "none") lifecycle=\(session?.lifecycle ?? "idle") journal_durable=\(session?.journalDurable ?? false) media_files_open=\(session?.mediaFilesOpen ?? false)"
    )
  }

  static func commandInvoked(_ command: String) {
    emit(commands, category: "Commands", message: "command=\(command)")
  }

  static func captureProof(stage: String, detail: String) {
    emit(capture, category: "CaptureProof", message: "stage=\(stage) detail=\(detail)")
  }

  static func captureSourceHealth(_ record: CaptureSourceHealthTelemetryRecord) {
    // Progress arrives with the audio callback. The unified log keeps it;
    // the in-app journal keeps only the route and writer changes.
    emit(
      capture, category: "CaptureProof", message: record.privacySafeMessage,
      journal: record.observation.event != .progress)
  }

  static func recoveryProof(stage: String, detail: String) {
    emit(recovery, category: "RecoveryProof", message: "stage=\(stage) detail=\(detail)")
  }

  static func launchFailed(_ failure: String) {
    emit(launch, category: "Launch", message: "single_instance_failure=\(failure)", failure: true)
  }

  static func launchAdmitted(microphone: String, screenCapture: String) {
    emit(
      launch, category: "Launch",
      message:
        "admitted microphone=\(DiagnosticPrivacy.token(microphone)) screen_capture=\(DiagnosticPrivacy.token(screenCapture))"
    )
  }

  static func libraryNote(stage: String, detail: String) {
    emit(library, category: "Library", message: "stage=\(stage) detail=\(detail)")
  }

  static func performanceStall(operation: String, milliseconds: Int) {
    emit(
      performance, category: "Performance",
      message: "operation=\(operation) milliseconds=\(milliseconds)")
  }
}
