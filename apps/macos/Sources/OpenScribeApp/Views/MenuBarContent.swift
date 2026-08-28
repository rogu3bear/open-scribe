import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController

  @MainActor
  init(
    store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil
  ) {
    self.store = store
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
      Button("Record Microphone + System Audio") {
        Task {
          await liveRecording.start()
          store.refresh()
        }
      }
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
    if let recovered = recoveredSessions.sessions.first {
      Divider()
      Label("Recovered conversation", systemImage: "waveform.badge.checkmark")
      Text("Playable local audio")
        .foregroundStyle(.secondary)
      if recoveredSessions.playingSessionId == recovered.sessionId {
        Button("Stop Recovered Audio") {
          recoveredSessions.stopPlayback()
        }
      } else {
        Button("Play Recovered Audio") {
          recoveredSessions.play(recovered)
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

  private var pendingStatusText: String {
    switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .failed: "Recording needs attention"
    default: "Ready to record microphone + system audio"
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
          "Recording microphone and system audio, \(session.timerText)"
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
      ("Starting microphone + system audio", "waveform", liveStatus)
    case .failed:
      ("Recording needs attention", "exclamationmark.circle", liveStatus)
    case .saved:
      ("Conversation audio saved", "waveform.badge.checkmark", liveStatus)
    case .requestingPermission, .preparing, .stopping:
      (liveStatus, "waveform", liveStatus)
    case .idle:
      ("Open Scribe", "record.circle", liveStatus)
    }
  }
}
