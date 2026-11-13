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
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var speech: SpeechTranscriptionModel
  /// Copies a saved conversation's transcript, as the window's Copy does.
  var copyConversation: (@MainActor (RuntimeSessionPresentation) -> Void)?

  @MainActor
  init(
    store: RuntimeLibraryStore,
    importedMediaAuthority: ImportedMediaAuthorityAdapter,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil,
    context: ContextScopeModel? = nil,
    navigation: MainWorkspaceNavigation? = nil,
    scheduler: TranscriptionScheduler? = nil,
    speech: SpeechTranscriptionModel? = nil,
    copyConversation: (@MainActor (RuntimeSessionPresentation) -> Void)? = nil
  ) {
    self.copyConversation = copyConversation
    self.store = store
    self.importedMediaAuthority = importedMediaAuthority
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController(managedRoot: nil)
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
    self.context = context ?? ContextScopeModel(binding: { nil })
    self.navigation = navigation ?? MainWorkspaceNavigation()
    self.scheduler = scheduler ?? TranscriptionScheduler.inert()
    self.speech = speech ?? SpeechTranscriptionModel(speech: nil)
  }

  var body: some View {
    let library = store.library
    let status = CaptureStatusPresentation.current(
      session: store.currentSession, snapshotStale: false, livePhase: liveRecording.phase,
      liveText: liveRecording.statusText)
    CaptureStatusLabel(text: status.text, symbolName: status.symbolName)
      .accessibilityLabel(status.accessibilityText)
    if let timer = status.timer {
      Text(timer)
        .font(.system(.body, design: .monospaced))
    }
    if let current = library.now {
      ForEach(current.sources, id: \.kind) { source in
        Label("\(source.name): \(source.stateText)", systemImage: source.symbolName)
      }
    }
    if let current = store.currentSession, !current.didNotRecord,
      let attention = current.interruptionText
    {
      CaptureIssueLabel(message: attention)
    }
    if let errorMessage = liveRecording.errorMessage {
      CaptureIssueLabel(message: errorMessage, isFailure: true)
    }
    if let storageNotice = liveRecording.storagePressureNotice {
      CaptureIssueLabel(message: storageNotice)
    }
    if let libraryError = store.errorMessage {
      CaptureIssueLabel(message: libraryError, isFailure: true)
    }
    let savedCount = library.saved.count
    if savedCount > 0 {
      Text(
        "\(store.isSnapshotStale ? "Last known: " : "")\(savedCount) saved conversation\(savedCount == 1 ? "" : "s")"
      )
      .foregroundStyle(.secondary)
    }
    if let copyConversation, let latest = library.latestCopyable {
      Button("Copy “\(library.titles[latest.sessionId] ?? latest.displayTitle)”") {
        copyConversation(latest)
      }
      .help("Copy the most recent conversation's transcript, ready to paste")
    }
    if let activity = scheduler.summaryText(titles: library.titles, progress: speech.progressFraction)
    {
      Text(activity)
        .foregroundStyle(.secondary)
        .accessibilityLabel(activity)
    }
    if liveRecording.canStart {
      HostedButton(
        title: Self.recordTitle(
          lifecycle: store.currentSession?.lifecycle,
          summary: liveRecording.sourceSelectionPresentation.summary),
        identifier: "Menu bar record", shortcut: ConversationControlLabels.recordShortcut,
        isEnabled: recordActionEnabled
      ) {
        Task {
          await liveRecording.start()
          store.refresh()
        }
      }
    }
    if liveRecording.canStop {
      HostedButton(
        title: ConversationControlLabels.stopAndSave, identifier: "Menu bar stop",
        shortcut: ConversationControlLabels.stopShortcut
      ) {
        Task {
          await liveRecording.stop()
          store.refresh()
        }
      }
    }
    RecorderControls(recorder: liveRecording, store: store)
    RecorderSourcesControl(recorder: liveRecording, store: store, presentation: .menu)
    ContextMenuSection(model: context)
    if let recovered = library.preservedConversation(media: recoveredSessions.sessions) {
      Divider()
      let title = library.titles[recovered.sessionId] ?? recovered.displayTitle
      let reference = library.references[recovered.sessionId]
      Text("\(title)\(reference.map { " · \($0)" } ?? "")")
        .help(title)
        .accessibilityLabel("\(title)\(reference.map { ", reference \($0)" } ?? "")")
      Text("Its audio is saved and ready to review.")
        .foregroundStyle(.secondary)
      Button(ConversationControlLabels.reviewPreservedAudio) {
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

  /// The one capture action in an idle menu. An interrupted session offers a
  /// new recording; every other idle menu names the selected sources.
  static func recordTitle(lifecycle: NativeSessionLifecycle?, summary: String) -> String {
    lifecycle == .interrupted ? "Start New Recording" : "Record — \(summary)"
  }

  static func statusSymbol(for session: RuntimeSessionPresentation) -> String {
    session.captureStatusSymbolName
  }

  static func preservedConversation(
    in sessions: [RuntimeSessionPresentation], media: [NativeRecoveredPlayableSession]
  ) -> RuntimeSessionPresentation? {
    LibraryPresentation.preservedConversation(in: sessions, media: media)
  }

  private func openPrimaryWindow() {
    AppTelemetry.commandInvoked("open-primary")
    if !MainWindow.focusExisting() {
      openWindow(id: "main")
    }
  }
}

struct MenuBarLabel: View {
  @Environment(\.isSceneVerification) private var isSceneVerification
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
          if isSceneVerification,
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
    let status = CaptureStatusPresentation.current(
      session: session, snapshotStale: snapshotStale, livePhase: livePhase, liveText: liveStatus)
    return (status.statusItemText, status.symbolName, status.accessibilityText)
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
