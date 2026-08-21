import Foundation
import OSLog

enum AppTelemetry {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "app.open-scribe.dev"
  private static let scenes = Logger(subsystem: subsystem, category: "Scenes")
  private static let commands = Logger(subsystem: subsystem, category: "Commands")

  static func sceneAppeared(_ scene: String, status: AppStatus) {
    scenes.info(
      "scene=\(scene, privacy: .public) rust_core_version=\(status.coreVersion, privacy: .public)"
    )
  }

  static func sceneAppeared(_ scene: String, snapshot: SessionPresentation) {
    scenes.info(
      "scene=\(scene, privacy: .public) fixture=\(snapshot.fixtureName, privacy: .public) lifecycle=\(snapshot.lifecycle, privacy: .public) presentation=\(snapshot.presentation, privacy: .public) journal_durable=\(snapshot.journalDurable, privacy: .public) media_files_open=\(snapshot.mediaFilesOpen, privacy: .public)"
    )
  }

  static func commandInvoked(_ command: String) {
    commands.info("command=\(command, privacy: .public)")
  }
}
