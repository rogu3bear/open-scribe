import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The main window: the library on the left; on the right, the recording in
/// progress as a live transcript, or a saved conversation as an interview.
struct ContentView: View {
  @Environment(\.isSceneVerification) private var isSceneVerification
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var pressure: SystemPressureMonitor
  @ObservedObject var context: ContextScopeModel
  @ObservedObject var navigation: MainWorkspaceNavigation
  /// Titles and name suggestions. Hosted proofs keep the inert default, so
  /// no language model runs inside them.
  @ObservedObject var suggestions: ConversationSuggestionModel = .inert
  /// Transcript export asks for a destination. The panel is the shipped
  /// default; a hosted proof can supply a file URL and still press Export.
  var exportTranscriptDestination: @MainActor (String) -> URL? = ConversationExportPanel.choose
  @StateObject private var librarySearch = LibrarySearchState()

  private var selectedSessionId: String? {
    navigation.selectedSessionId
  }

  private var selectedSession: RuntimeSessionPresentation? {
    store.library.session(selectedSessionId)
  }

  private var canRecord: Bool {
    MainWorkspaceActions.canRecord(
      liveCanStart: liveRecording.canStart, importIsBusy: importedMediaAuthority.isBusy)
  }

  private var actions: ConversationActions {
    ConversationActions(
      store: store, transcripts: transcripts, playback: recoveredSessions,
      recorderIdle: liveRecording.canStart)
  }

  var body: some View {
    NavigationSplitView {
      LibrarySidebar(
        store: store, importedMediaAuthority: importedMediaAuthority,
        liveRecording: liveRecording, transcripts: transcripts, speech: speech,
        scheduler: scheduler, pressure: pressure, navigation: navigation,
        search: librarySearch, actions: actions,
        onOpenSearchHit: openSearchHit
      )
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      AudioDropMount { urls in
        importedMediaAuthority.stageDroppedAudio(urls)
      }
    }
    .toolbar {
      // Record is its own item, so it reads as the window's one capture
      // action rather than sharing a capsule with Sources.
      ToolbarItem(placement: .primaryAction) { captureButton }
      ToolbarItemGroup(placement: .primaryAction) {
        RecorderControls(recorder: liveRecording, store: store)
      }
      ToolbarItem(placement: .primaryAction) {
        RecorderSourcesControl(recorder: liveRecording, store: store)
      }
      ToolbarItemGroup(placement: .primaryAction) { importButton }
    }
    .onAppear {
      store.refresh()
      AppTelemetry.runtimeSceneAppeared("primary", session: store.currentSession)
      let library = store
      suggestions.onTitleStored = { library.refresh() }
      // Selection is published state. Applying it on the next turn keeps the
      // first library layout from redrawing inside its own appearance pass.
      Task { @MainActor in
        synchronizeSelection(preferCurrentSession: navigation.selectedSessionId == nil)
      }
    }
    .onChange(of: store.currentSession?.sessionId) { _ in
      synchronizeSelection(preferCurrentSession: false)
    }
    .onChange(of: store.savedSessions.map(\.sessionId)) { _ in
      synchronizeSelection(preferCurrentSession: false)
    }
    .onReceive(store.$savedSessions) { sessions in
      suggestions.considerLibrary(sessions)
    }
    .onReceive(liveRecording.liveCaptions.$lines) { lines in
      guard let sessionId = store.currentSession?.sessionId, liveRecording.canStop else { return }
      suggestions.considerLive(sessionId: sessionId, lines: lines)
    }
    .onChange(of: importedMediaAuthority.importedSessionId) { importedSessionId in
      navigation.acceptImportedConversation(
        importedSessionId,
        savedSessionIds: store.savedSessions.map(\.sessionId)
      )
    }
    .task(id: librarySearch.query) {
      await transcripts.search(librarySearch.query)
    }
    .onChange(of: selectedSessionId) { selectedSessionId in
      if MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: recoveredSessions.activePlaybackSessionId,
        selectedSessionId: selectedSessionId
      ) {
        recoveredSessions.stopPlayback()
      }
    }
    .background {
      #if DEBUG
        if isSceneVerification { VerificationSettingsTrigger() }
      #endif
    }
  }

  // MARK: Detail

  /// The selected document fills the column from the toolbar down; the
  /// window's notices sit inside it, in the document's notice position.
  @ViewBuilder private var document: some View {
    if let selectedSession {
      if selectedSession.sessionId == store.currentSession?.sessionId,
        selectedSession.lifecycle != .interrupted
      {
        CompactLiveView(
          store: store, liveRecording: liveRecording, context: context,
          actions: actions, notices: windowNotices)
      } else {
        ConversationWorkspaceView(
          session: selectedSession,
          store: store,
          playbackController: recoveredSessions,
          transcripts: transcripts,
          speech: speech,
          scheduler: scheduler,
          reference: store.library.references[selectedSession.sessionId],
          audioReviewRequest: navigation.audioReviewRequest,
          canStartNewRecording: canRecord,
          newRecordingUnavailableReason: importedMediaAuthority.isBusy
            ? "Wait for the current import to finish before starting a new recording."
            : liveRecording.isLaunchRecoveryPending()
              ? liveRecording.readinessText
              : "Finish the current recording action before starting a new recording.",
          onStartNewRecording: startRecording,
          loadRecorderEvents: { (try? liveRecording.detail(sessionId: $0).events) ?? [] },
          suggestions: suggestions,
          exportDestination: exportTranscriptDestination,
          windowNotices: windowNotices
        )
        .id(selectedSession.sessionId)
      }
    } else {
      EmptyConversationWorkspace(
        canRecord: canRecord,
        canImport: canImport,
        hasConversations: !store.library.isEmpty,
        recordedAudio: liveRecording.captureSelection.recordedAudio,
        notices: windowNotices,
        onRecord: startRecording,
        onOpenPackage: openPackageAction
      )
    }
  }

  private var detail: some View {
    document
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Interview.paper)
      .overlay(alignment: .top) {
        DropConfirmationMount(authority: importedMediaAuthority)
          .frame(maxWidth: .infinity)
      }
      .overlay(alignment: .bottom) {
        // Pending rename and deletion are published after the first layout.
        // These strips are created with it and reveal their own controls.
        VStack(spacing: 0) {
          RenameConfirmationMount(store: store)
            .frame(maxWidth: .infinity)
          DeletionConfirmationMount(transcripts: transcripts) {
            store.refresh()
          }
          .frame(maxWidth: .infinity)
        }
      }
  }

  // MARK: Toolbar

  /// Record, or Stop and Save in its place while recording.
  @ViewBuilder private var captureButton: some View {
    if liveRecording.canStop {
      HostedButton(
        title: ConversationControlLabels.stopAndSave, symbol: "stop.fill",
        identifier: "Toolbar stop", shortcut: ConversationControlLabels.stopShortcut
      ) {
        Task {
          await liveRecording.stop()
          store.refresh()
        }
      }
    } else {
      HostedButton(
        title: ConversationControlLabels.record, identifier: "Toolbar record",
        shortcut: ConversationControlLabels.recordShortcut,
        help: "Record \(liveRecording.captureSelection.recordedAudio)", style: .record,
        isEnabled: canRecord, action: startRecording)
    }
  }

  @ViewBuilder
  private var importButton: some View {
    if importedMediaAuthority.hasPendingAudioImports
      || !importedMediaAuthority.failedImports.isEmpty
    {
      ImportBatchStatus(imports: importedMediaAuthority, canResume: liveRecording.canStart)
    }
    if !importedMediaAuthority.hasPendingAudioImports, importedMediaAuthority.canOpenPackages {
      Menu(
        importedMediaAuthority.isBusy ? "Importing…" : "Import",
        systemImage: "square.and.arrow.down"
      ) {
        Button("Audio Files…", systemImage: "waveform") {
          importedMediaAuthority.chooseAndImport()
        }
        .disabled(!canImport)
        openPackageButton
      }
      .disabled(!canImport)
      .help(
        canImport
          ? ImportedMediaAuthorityAdapter.importLimitHelp
          : liveRecording.isLaunchRecoveryPending()
            ? "Wait for the check of recordings from the last session to finish before importing audio"
            : "Wait for the current recording action to finish before importing audio"
      )
    }
  }

  private var openPackageAction: (@MainActor () -> Void)? {
    guard importedMediaAuthority.canOpenPackages else { return nil }
    let authority = importedMediaAuthority
    return { authority.chooseAndOpenPackage() }
  }

  private var openPackageButton: some View {
    Button("Open Portable Package…", systemImage: "shippingbox") {
      importedMediaAuthority.chooseAndOpenPackage()
    }
    .keyboardShortcut("o", modifiers: .command)
    .disabled(!canImport)
    .help(
      canImport
        ? ImportedMediaAuthorityAdapter.portablePackageHelp
        : ImportedMediaAuthorityAdapter.portablePackageWaitHelp
    )
  }

  private var canImport: Bool {
    liveRecording.canStart && !importedMediaAuthority.isBusy
      && !importedMediaAuthority.hasPendingAudioImports
  }

  // MARK: Notices

  private var windowNotices: WindowNotices {
    var others = [WorkspaceNotice]()
    if let message = store.errorMessage {
      others.append(.init(id: "library", message: message, isFailure: true))
    }
    if let message = recoveredSessions.errorMessage,
      recoveredSessions.errorSessionId == nil
    {
      others.append(.init(id: "playback", message: message, isFailure: true))
    }
    if importedMediaAuthority.phase == .failed,
      let message = importedMediaAuthority.statusMessage
    {
      others.append(.init(id: "import", message: message, isFailure: true))
    } else if others.isEmpty, importedMediaAuthority.pendingAudioImport == nil,
      let message = importedMediaAuthority.statusMessage
    {
      others.append(.init(id: "import", message: message, isFailure: false))
    }
    if let message = transcripts.message {
      others.append(
        .init(id: "transcripts", message: message, isFailure: transcripts.messageIsFailure))
    }
    var edit: WorkspaceNotice?
    if let message = store.editMessage, store.pendingRename == nil {
      edit = .init(id: "edit", message: message, isFailure: store.editMessageIsFailure)
    }
    if others.isEmpty, edit == nil, liveRecording.phase == .saved,
      selectedSessionId == liveRecording.lastSavedSessionId,
      let message = liveRecording.mixdownStatus
    {
      others.append(.init(id: "mixdown", message: message, isFailure: false))
    }
    return WindowNotices(
      recordingProblem: liveRecording.errorMessage, edit: edit, others: others)
  }

  // MARK: Actions

  private func startRecording() {
    Task {
      await liveRecording.start()
      store.refresh()
      synchronizeSelection(preferCurrentSession: true)
    }
  }

  private func openSearchHit(_ hit: NativeTranscriptSearchHit) {
    navigation.select(hit.sessionId)
    if let session = store.savedSessions.first(where: {
      $0.sessionId == hit.sessionId
    }) {
      recoveredSessions.playTranscriptSearchHit(hit, in: session)
    }
  }

  /// Selection lands only on sessions the sidebar lists. An attempt that
  /// never recorded has no row of its own; a failed start stays in the
  /// window's problem banner instead.
  private func synchronizeSelection(preferCurrentSession: Bool) {
    navigation.synchronize(
      currentSessionId: store.currentSession.flatMap { $0.didNotRecord ? nil : $0.sessionId },
      savedSessionIds: store.savedSessions.filter { !$0.didNotRecord }.map(\.sessionId),
      preferCurrentSession: preferCurrentSession
    )
  }
}

/// The window before any conversation is chosen: one sentence about what
/// Open Scribe does, and the two ways to begin.
private struct EmptyConversationWorkspace: View {
  let canRecord: Bool
  let canImport: Bool
  let hasConversations: Bool
  let recordedAudio: String
  let notices: WindowNotices
  let onRecord: @MainActor () -> Void
  let onOpenPackage: (@MainActor () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(hasConversations ? "Choose a conversation" : "Record a conversation")
        .font(Interview.title(34))
        .foregroundStyle(Interview.ink)
        .accessibilityAddTraits(.isHeader)
      Text(
        "Open Scribe records \(recordedAudio), writes a transcript while you talk, and keeps everything on this Mac. When you stop, Copy puts the whole conversation on the clipboard with names and times."
      )
      .font(Interview.speech())
      .foregroundStyle(Interview.quiet)
      .lineSpacing(Interview.speechLineSpacing)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        HostedButton(
          title: ConversationControlLabels.record, identifier: "Record conversation",
          style: .record, isEnabled: canRecord, action: onRecord)
        if let onOpenPackage {
          HostedButton(
            title: ConversationControlLabels.portablePackage, identifier: "Open portable package",
            help: canImport
              ? ImportedMediaAuthorityAdapter.portablePackageHelp
              : ImportedMediaAuthorityAdapter.portablePackageWaitHelp,
            style: .large, isEnabled: canImport, action: onOpenPackage)
        }
      }
      .padding(.top, 6)
      WindowNoticeList(notices: notices)
      Text("You can also drop an audio file (M4A or CAF) anywhere in this window.")
        .font(Interview.meta)
        .foregroundStyle(Interview.quiet)
    }
    .frame(maxWidth: 520, alignment: .leading)
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}
