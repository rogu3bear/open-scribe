import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var context: ContextScopeModel
  @ObservedObject var navigation: MainWorkspaceNavigation

  @MainActor
  init(
    store: RuntimeLibraryStore,
    importedMediaAuthority: ImportedMediaAuthorityAdapter,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil,
    context: ContextScopeModel? = nil,
    navigation: MainWorkspaceNavigation? = nil
  ) {
    self.store = store
    self.importedMediaAuthority = importedMediaAuthority
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController()
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
    self.context = context ?? ContextScopeModel(binding: { nil })
    self.navigation = navigation ?? MainWorkspaceNavigation()
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
        CaptureIssueLabel(message: interruption)
      }
    } else {
      Text(pendingStatusText)
        .accessibilityLabel(pendingStatusText)
    }
    if let errorMessage = liveRecording.errorMessage {
      CaptureIssueLabel(message: errorMessage, isFailure: true)
    }
    if let libraryError = store.errorMessage {
      CaptureIssueLabel(message: libraryError, isFailure: true)
    }
    let savedCount = LibraryConversationLists.saved(store.savedSessions).count
    if savedCount > 0 {
      Text(
        "\(store.isSnapshotStale ? "Last known: " : "")\(savedCount) saved conversation\(savedCount == 1 ? "" : "s")"
      )
      .foregroundStyle(.secondary)
    }
    if liveRecording.canStart {
      Button(
        store.currentSession?.lifecycle == "interrupted"
          ? "Start New Recording" : "Record — \(liveRecording.sourceSelectionPresentation.summary)"
      ) {
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
    let conversations = (store.currentSession.map { [$0] } ?? []) + store.savedSessions
    if let recovered = Self.preservedConversation(
      in: conversations, media: recoveredSessions.sessions
    ) {
      Divider()
      let title = ConversationIdentityPresentation.title(recovered.title)
      let reference = ConversationIdentityPresentation.references(for: conversations)[
        recovered.sessionId]
      Text("\(title)\(reference.map { " · \($0)" } ?? "")")
        .help(recovered.title)
        .accessibilityLabel("\(title)\(reference.map { ", reference \($0)" } ?? "")")
      Text("Verified local audio is available for review.")
        .foregroundStyle(.secondary)
      Button("Review Preserved Audio") {
        navigation.reviewPreservedAudio(sessionId: recovered.sessionId)
        openPrimaryWindow()
      }
    }
    if recoveredSessions.activePlaybackSessionId != nil {
      let playbackAction = PlaybackControlAction.resolve(
        isPending: recoveredSessions.playingSessionId == nil,
        isPlaying: recoveredSessions.playingSessionId != nil
      )
      Button("\(playbackAction.title) Audio") {
        recoveredSessions.stopPlayback()
      }
    }
    if let recoveryError = recoveredSessions.errorMessage {
      CaptureIssueLabel(message: recoveryError, isFailure: true)
    }
    Divider()
    Button("Open Open Scribe") {
      openPrimaryWindow()
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

  static func preservedConversation(
    in sessions: [RuntimeSessionPresentation], media: [NativeRecoveredPlayableSession]
  ) -> RuntimeSessionPresentation? {
    sessions.first {
      ($0.lifecycle == "interrupted" || $0.lifecycle == "ready_for_review")
        && ($0.needsAttention || $0.recovered) && $0.hasVerifiedPreservedAudio(from: media)
    }
  }

  private func openPrimaryWindow() {
    AppTelemetry.commandInvoked("open-primary")
    if !MainWindow.focusExisting() {
      openWindow(id: "main")
    }
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
