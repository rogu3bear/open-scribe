import Foundation
import OSLog

struct CaptureSourceHealthTelemetryRecord: Equatable, Sendable {
  let observation: MicrophoneSourceHealthObservation
  let rustSourceState: String
  let visibleState: String

  var privacySafeMessage: String {
    [
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
  }
}

enum AppTelemetry {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "app.open-scribe.dev"
  private static let scenes = Logger(subsystem: subsystem, category: "Scenes")
  private static let commands = Logger(subsystem: subsystem, category: "Commands")
  private static let capture = Logger(subsystem: subsystem, category: "CaptureProof")
  private static let recovery = Logger(subsystem: subsystem, category: "RecoveryProof")
  private static let launch = Logger(subsystem: subsystem, category: "Launch")
  private static let performance = Logger(subsystem: subsystem, category: "Performance")
  static let signposter = OSSignposter(subsystem: subsystem, category: "Performance")

  private static func note(_ category: String, _ message: String) {
    DiagnosticJournal.shared.record(category: category, message: message)
  }

  static func sceneAppeared(_ scene: String, status: AppStatus) {
    let message = "scene=\(scene) rust_core_version=\(status.coreVersion)"
    scenes.info(
      "scene=\(scene, privacy: .public) rust_core_version=\(status.coreVersion, privacy: .public)"
    )
    note("Scenes", message)
  }

  static func sceneAppeared(_ scene: String, snapshot: SessionPresentation) {
    let message =
      "scene=\(scene) fixture=\(snapshot.fixtureName) lifecycle=\(snapshot.lifecycle) presentation=\(snapshot.presentation) journal_durable=\(snapshot.journalDurable) media_files_open=\(snapshot.mediaFilesOpen)"
    scenes.info(
      "scene=\(scene, privacy: .public) fixture=\(snapshot.fixtureName, privacy: .public) lifecycle=\(snapshot.lifecycle, privacy: .public) presentation=\(snapshot.presentation, privacy: .public) journal_durable=\(snapshot.journalDurable, privacy: .public) media_files_open=\(snapshot.mediaFilesOpen, privacy: .public)"
    )
    note("Scenes", message)
  }

  static func runtimeSceneAppeared(_ scene: String, session: RuntimeSessionPresentation?) {
    let message =
      "scene=\(scene) runtime_session=\(session?.sessionId ?? "none") lifecycle=\(session?.lifecycle ?? "idle") journal_durable=\(session?.journalDurable ?? false) media_files_open=\(session?.mediaFilesOpen ?? false)"
    scenes.info(
      "scene=\(scene, privacy: .public) runtime_session=\(session?.sessionId ?? "none", privacy: .public) lifecycle=\(session?.lifecycle ?? "idle", privacy: .public) journal_durable=\(session?.journalDurable ?? false) media_files_open=\(session?.mediaFilesOpen ?? false)"
    )
    note("Scenes", message)
  }

  static func commandInvoked(_ command: String) {
    commands.info("command=\(command, privacy: .public)")
    note("Commands", "command=\(command)")
  }

  static func captureProof(stage: String, detail: String) {
    capture.info("stage=\(stage, privacy: .public) detail=\(detail, privacy: .public)")
    note("CaptureProof", "stage=\(stage) detail=\(detail)")
  }

  static func captureSourceHealth(_ record: CaptureSourceHealthTelemetryRecord) {
    capture.info("\(record.privacySafeMessage, privacy: .public)")
    note("CaptureProof", record.privacySafeMessage)
  }

  static func recoveryProof(stage: String, detail: String) {
    recovery.info("stage=\(stage, privacy: .public) detail=\(detail, privacy: .public)")
    note("RecoveryProof", "stage=\(stage) detail=\(detail)")
  }

  static func launchFailed(_ failure: String) {
    launch.error("single_instance_failure=\(failure, privacy: .public)")
    note("Launch", "single_instance_failure=\(failure)")
  }

  static func performanceStall(operation: String, milliseconds: Int) {
    performance.info(
      "operation=\(operation, privacy: .public) milliseconds=\(milliseconds, privacy: .public)")
    note("Performance", "operation=\(operation) milliseconds=\(milliseconds)")
  }
}
