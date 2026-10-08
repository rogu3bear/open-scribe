import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var context: ContextScopeModel

  @MainActor
  init(
    store: RuntimeLibraryStore,
    importedMediaAuthority: ImportedMediaAuthorityAdapter,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil,
    context: ContextScopeModel? = nil
  ) {
    self.store = store
    self.importedMediaAuthority = importedMediaAuthority
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController()
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
    self.context = context ?? ContextScopeModel(binding: { nil })
  }

  var body: some View {
    if let current = store.currentSession {
      CaptureStatusLabel(text: current.statusText, symbolName: Self.statusSymbol(for: current))
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
    let savedCount = LibraryConversationLists.saved(store.savedSessions).count
    if savedCount > 0 {
      Text(
        "\(store.isSnapshotStale ? "Last known: " : "")\(savedCount) saved conversation\(savedCount == 1 ? "" : "s")"
      )
      .foregroundStyle(.secondary)
    }
    if liveRecording.canStart {
      Button("Record — \(liveRecording.sourceSelectionPresentation.summary)") {
        Task {
          await liveRecording.start()
          store.refresh()
        }
      }
      .disabled(!recordActionEnabled)
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }
    if liveRecording.canStop {
      Button("Stop and Save") {
        Task {
          await liveRecording.stop()
          store.refresh()
        }
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }
    RecorderControls(recorder: liveRecording, store: store, sourcesPresentation: .menu)
    ContextMenuSection(model: context)
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
      if !MainWindow.focusExisting() {
        openWindow(id: "main")
      }
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

  static func statusSymbol(for session: RuntimeSessionPresentation) -> String {
    session.captureStatusSymbolName
  }

  private var pendingStatusText: String {
    switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting, .pausing, .paused: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .saved: liveRecording.statusText
    case .failed: liveRecording.statusText
    default: liveRecording.readinessText
    }
  }
}

struct MenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  var body: some View {
    let presentation = Self.presentation(
      session: store.currentSession,
      snapshotStale: store.isSnapshotStale,
      livePhase: liveRecording.phase,
      liveStatus: liveRecording.statusText
    )
    CaptureStatusLabel(text: presentation.text, symbolName: presentation.symbolName)
      .accessibilityLabel(presentation.accessibilityText)
      .onAppear {
        store.refresh()
        AppTelemetry.runtimeSceneAppeared("menu-bar", session: store.currentSession)
        #if DEBUG
          // The explicit scene proof must also work after macOS restores a
          // menu-bar-only launch. Its primary scene opens Settings in turn.
          if ProcessInfo.processInfo.arguments.contains("--m0-proof-settings"),
            !MainWindow.focusExisting()
          {
            openWindow(id: "main")
          }
        #endif
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

  static func presentation(
    session: RuntimeSessionPresentation?,
    snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase,
    liveStatus: String
  ) -> (text: String, symbolName: String, accessibilityText: String) {
    if snapshotStale {
      return ("State unavailable", "exclamationmark.circle", "Live recording state unavailable")
    }
    if let session {
      if let paused = session.pausedStatusSymbolName {
        return (
          "\(session.statusText) · \(session.timerText)", paused,
          "\(session.statusText), \(session.timerText)"
        )
      }
      if session.isRecording {
        return (
          "Recording · \(session.timerText)",
          session.captureStatusSymbolName,
          "Recording \(session.capturingSourcesText), \(session.timerText)"
        )
      }
      return (
        session.statusText,
        session.captureStatusSymbolName,
        session.statusText
      )
    }
    return switch livePhase {
    case .capturing:
      (
        "Confirming recording", SymbolResolver.captureSymbol(for: .starting),
        "Confirming durable recording"
      )
    case .starting:
      (liveStatus, SymbolResolver.captureSymbol(for: .starting), liveStatus)
    case .paused:
      (liveStatus, SymbolResolver.pausedCaptureSymbolName, liveStatus)
    case .failed:
      (liveStatus, "exclamationmark.circle", liveStatus)
    case .saved:
      (liveStatus, "waveform.badge.checkmark", liveStatus)
    case .requestingPermission, .preparing, .pausing, .stopping:
      (liveStatus, SymbolResolver.captureSymbol(for: .starting), liveStatus)
    case .idle:
      ("Open Scribe", SymbolResolver.captureSymbol(for: .ready), liveStatus)
    }
  }
}

private struct CaptureStatusLabel: View {
  let text: String
  let symbolName: String

  var body: some View {
    if symbolName.isEmpty {
      Text(text)
    } else {
      Label(text, systemImage: symbolName)
    }
  }
}
