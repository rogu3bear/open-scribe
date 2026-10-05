import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }
  var text: String

  init(text: String) { self.text = text }

  init(configuration: ReadConfiguration) throws {
    text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

struct SettingsView: View {
  let status: AppStatus
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var library: RuntimeLibraryStore
  @ObservedObject var recovery: RecoveredSessionController
  @State private var exportDocument = DiagnosticsDocument(text: "")
  @State private var exportPresented = false
  @ObservedObject private var diagnosticLog = DiagnosticLog.shared
  @State private var signature = "checking"

  var body: some View {
    Form {
      Section("Diagnostics") {
        LabeledContent("Microphone", value: microphoneLabel)
        LabeledContent("Screen Recording", value: screenCaptureLabel)
        LabeledContent("Signature", value: signature)
        LabeledContent("Recovery", value: recoveryLabel)
        LabeledContent("Library", value: libraryLabel)
        LabeledContent(
          "Models",
          value: "\(speech.models.filter(\.installed).count) installed of \(speech.models.count)")
        Text("Recent notes stay on this Mac. They omit titles, transcript text, and file paths.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if diagnosticLog.events.isEmpty {
          Text("No notes yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(diagnosticLog.events.suffix(12)) { event in
            Text(
              "\(event.recordedAt.formatted(.dateTime.hour().minute().second()))  \(event.category)  \(event.message)"
            )
            .font(.caption.monospaced())
            .textSelection(.enabled)
          }
        }
        Button("Export Diagnostics…") {
          exportDocument = DiagnosticsDocument(text: currentReport())
          exportPresented = true
          AppTelemetry.commandInvoked("export-diagnostics")
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 320)
    .onAppear {
      AppTelemetry.sceneAppeared("settings", status: status)
      speech.refresh()
      diagnosticLog.replace(DiagnosticJournal.shared.recent())
      Task { @MainActor in
        let status = await Task.detached(priority: .utility) {
          DiagnosticsSignature.current()
        }.value
        signature = status
      }
    }
    .fileExporter(
      isPresented: $exportPresented,
      document: exportDocument,
      contentType: .plainText,
      defaultFilename: "Open Scribe Diagnostics"
    ) { result in
      if case .failure(let error) = result {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
          return
        }
        AppTelemetry.commandInvoked("export-diagnostics-failed")
      }
    }
  }

  private var recoveryLabel: String {
    switch recovery.phase {
    case .scanning: "Scanning"
    case .none: "Nothing to recover"
    case .available: "\(recovery.sessions.count) playable"
    case .failed: "Needs attention"
    }
  }

  private var libraryLabel: String {
    let saved = library.savedSessions.count
    let live = library.currentSession == nil ? 0 : 1
    return "\(saved + live) conversations"
  }

  private var sessionLines: [DiagnosticsReport.SessionLine] {
    let sessions = [library.currentSession].compactMap { $0 } + library.savedSessions
    return sessions.map {
      DiagnosticsReport.SessionLine(
        sessionId: $0.sessionId,
        lifecycle: $0.lifecycle,
        health: $0.health,
        recovered: $0.recovered,
        journalDurable: $0.journalDurable,
        mediaFilesOpen: $0.mediaFilesOpen
      )
    }
  }

  private var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }

  private var microphoneLabel: String {
    AVFoundationMicrophonePermissionAuthority().currentState.rawValue
  }

  private var screenCaptureLabel: String {
    CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized"
  }

  private func currentReport() -> String {
    DiagnosticsReport.text(
      product: status.productName,
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0",
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture,
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.open-scribe.dev",
      microphone: microphoneLabel,
      screenCapture: screenCaptureLabel,
      signature: signature,
      recoveryPhase: recovery.phase.diagnosticName,
      recoveredCount: recovery.sessions.count,
      sessions: sessionLines,
      models: speech.models.map {
        DiagnosticsReport.ModelLine(modelId: $0.modelId, fileName: $0.fileName, installed: $0.installed)
      },
      events: DiagnosticJournal.shared.recent()
    )
  }
}
