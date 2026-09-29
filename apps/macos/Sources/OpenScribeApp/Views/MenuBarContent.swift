import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController

  @MainActor
  init(
    store: RuntimeLibraryStore,
    importedMediaAuthority: ImportedMediaAuthorityAdapter,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil
  ) {
    self.store = store
    self.importedMediaAuthority = importedMediaAuthority
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController()
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
  }

  var body: some View {
    if let current = store.currentSession {
      Label(
        current.statusText,
        systemImage: current.isRecording ? "record.circle.fill" : "exclamationmark.circle")
      Text(current.timerText)
        .font(.system(.body, design: .monospaced))
      ForEach(current.sources, id: \.kind) { source in
        Label("\(source.name): \(source.stateText)", systemImage: source.symbolName)
      }
      if let interruption = current.interruptionText {
        Text(interruption)
          .foregroundStyle(.orange)
      }
    } else {
      Text(pendingStatusText)
        .accessibilityLabel(pendingStatusText)
    }
    if let errorMessage = liveRecording.errorMessage {
      Text(errorMessage)
        .foregroundStyle(.red)
    }
    if let libraryError = store.errorMessage {
      Text(libraryError)
        .foregroundStyle(.red)
    }
    if !store.savedSessions.isEmpty {
      Text(
        "\(store.isSnapshotStale ? "Last known: " : "")\(store.savedSessions.count) saved conversation\(store.savedSessions.count == 1 ? "" : "s")"
      )
      .foregroundStyle(.secondary)
    }
    if liveRecording.canStart {
      Button("Record — \(liveRecording.captureSelection.name)") {
        Task {
          await liveRecording.start()
          store.refresh()
        }
      }
      .disabled(!recordActionEnabled)
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }
    if liveRecording.canStop {
      Button("Stop Capture") {
        Task {
          await liveRecording.stop()
          store.refresh()
        }
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }
    RecorderControls(recorder: liveRecording, store: store, sourcesPresentation: .menu)
    if let recovered = recoveredSessions.sessions.first {
      Divider()
      Label("Recovered conversation", systemImage: "waveform.badge.checkmark")
      Text("Playable local audio")
        .foregroundStyle(.secondary)
      let playbackAction = PlaybackControlAction.resolve(
        isPending: recoveredSessions.pendingRecoveredMediaIdentity != nil,
        isPlaying: recoveredSessions.playingRecoveredMediaIdentity != nil
      )
      if playbackAction == .play {
        Button("Play Recovered Audio") {
          recoveredSessions.play(recovered)
        }
        .disabled(
          !playbackAction.isEnabled(
            hasActivePlayback: recoveredSessions.activePlaybackSessionId != nil
          )
        )
      } else {
        Button("\(playbackAction.title) Recovered Audio") {
          recoveredSessions.stopPlayback()
        }
      }
    }
    if let recoveryError = recoveredSessions.errorMessage {
      Text(recoveryError)
        .foregroundStyle(.red)
    }
    Divider()
    Button("Open Open Scribe") {
      AppTelemetry.commandInvoked("open-primary")
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    Button("Refresh Library") {
      store.refresh()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    if #available(macOS 14.0, *) {
      SettingsLink {
        Text("Settings…")
      }
    } else {
      Button("Settings…") {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      }
    }
    Divider()
    Button("Quit Open Scribe") {
      AppTelemetry.commandInvoked("quit")
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  var recordActionEnabled: Bool {
    MainWorkspaceActions.canRecord(
      liveCanStart: liveRecording.canStart,
      importIsBusy: importedMediaAuthority.isBusy
    )
  }

  private var pendingStatusText: String {
    switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .saved: liveRecording.statusText
    case .failed: "Recording needs attention"
    default: liveRecording.readinessText
    }
  }
}

struct MenuBarLabel: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  var body: some View {
    let presentation = Self.presentation(
      session: store.currentSession,
      snapshotStale: store.isSnapshotStale,
      livePhase: liveRecording.phase,
      liveStatus: liveRecording.statusText
    )
    Label(presentation.text, systemImage: presentation.symbolName)
      .accessibilityLabel(presentation.accessibilityText)
      .onAppear {
        store.refresh()
        AppTelemetry.runtimeSceneAppeared("menu-bar", session: store.currentSession)
      }
  }

  static func accessibilityStatus(
    session: RuntimeSessionPresentation?,
    snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase,
    liveStatus: String
  ) -> String {
    presentation(
      session: session,
      snapshotStale: snapshotStale,
      livePhase: livePhase,
      liveStatus: liveStatus
    ).accessibilityText
  }

  private static func presentation(
    session: RuntimeSessionPresentation?,
    snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase,
    liveStatus: String
  ) -> (text: String, symbolName: String, accessibilityText: String) {
    if snapshotStale {
      return ("State unavailable", "exclamationmark.circle", "Live recording state unavailable")
    }
    if let session {
      if session.isRecording {
        return (
          "Recording · \(session.timerText)",
          "record.circle.fill",
          "Recording \(session.capturingSourcesText), \(session.timerText)"
        )
      }
      return (
        session.statusText,
        session.needsAttention ? "exclamationmark.circle" : "waveform",
        session.statusText
      )
    }
    return switch livePhase {
    case .capturing:
      ("Confirming recording", "waveform", "Confirming durable recording")
    case .starting:
      (liveStatus, "waveform", liveStatus)
    case .pausing, .paused:
      (liveStatus, "pause.circle", liveStatus)
    case .failed:
      ("Recording needs attention", "exclamationmark.circle", liveStatus)
    case .saved:
      (liveStatus, "waveform.badge.checkmark", liveStatus)
    case .requestingPermission, .preparing, .stopping:
      (liveStatus, "waveform", liveStatus)
    case .idle:
      ("Open Scribe", "record.circle", liveStatus)
    }
  }
}
