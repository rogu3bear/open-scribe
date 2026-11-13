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
    if store.currentSession?.sessionId == selectedSessionId {
      return store.currentSession
    }
    return store.savedSessions.first { $0.sessionId == selectedSessionId }
  }

  private var canRecord: Bool {
    MainWorkspaceActions.canRecord(
      liveCanStart: liveRecording.canStart, importIsBusy: importedMediaAuthority.isBusy)
  }

  var body: some View {
    NavigationSplitView {
      LibrarySidebar(
        store: store, importedMediaAuthority: importedMediaAuthority,
        liveRecording: liveRecording, transcripts: transcripts, speech: speech,
        scheduler: scheduler, pressure: pressure, navigation: navigation,
        search: librarySearch,
        onOpenSearchHit: openSearchHit,
        onRequestDeletion: requestDeletion,
        onCopy: copyConversation
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
      ToolbarItemGroup(placement: .primaryAction) {
        captureButton
        RecorderControls(recorder: liveRecording, store: store)
        importButton
      }
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
      navigation.synchronize(
        currentSessionId: store.currentSession?.sessionId,
        savedSessionIds: store.savedSessions.map(\.sessionId),
        preferCurrentSession: false
      )
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

  private var detail: some View {
    VStack(spacing: 0) {
      statusBanner
      if let selectedSession {
        if selectedSession.sessionId == store.currentSession?.sessionId,
          selectedSession.lifecycle != "interrupted"
        {
          CompactLiveView(store: store, liveRecording: liveRecording, context: context)
        } else {
          ConversationWorkspaceView(
            session: selectedSession,
            store: store,
            playbackController: recoveredSessions,
            transcripts: transcripts,
            speech: speech,
            scheduler: scheduler,
            reference: ConversationIdentityPresentation.references(
              for: store.savedSessions + (store.currentSession.map { [$0] } ?? [])
            )[selectedSession.sessionId],
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
            exportDestination: exportTranscriptDestination
          )
          .id(selectedSession.sessionId)
        }
      } else {
        EmptyConversationWorkspace(
          canRecord: canRecord,
          canImport: canImport,
          hasConversations: !store.savedSessions.isEmpty,
          recordedAudio: liveRecording.captureSelection.recordedAudio,
          onRecord: startRecording,
          onOpenPackage: openPackageAction
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Interview.paper)
    .overlay(alignment: .top) {
      DropConfirmationMount(authority: importedMediaAuthority)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
    .overlay(alignment: .bottom) {
      // Pending rename and deletion are published after the first layout.
      // These strips are created with it and reveal their own controls.
      VStack(spacing: 0) {
        RenameConfirmationMount(store: store)
          .frame(maxWidth: .infinity)
          .frame(height: 112)
        DeletionConfirmationMount(transcripts: transcripts) {
          store.refresh()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
      }
    }
  }

  private var statusBanner: some View {
    VStack(spacing: 0) {
      RecordingProblemMount(message: liveRecording.errorMessage)
        .frame(
          maxWidth: .infinity,
          minHeight: liveRecording.errorMessage == nil ? 0 : 44,
          alignment: .leading)
      if !workspaceNotices.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(workspaceNotices) { notice in
            if notice.id == "edit" {
              LibraryNoticeMount(message: notice.message, isFailure: notice.isFailure)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.related) {
                Image(
                  systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle"
                )
                .foregroundStyle(notice.isFailure ? Color.orange : Color.secondary)
                Text(notice.message)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .font(Interview.meta)
              .foregroundStyle(notice.isFailure ? Color.primary : Color.secondary)
              .accessibilityElement(children: .combine)
              .accessibilityLabel(
                "\(notice.isFailure ? "Problem" : "Status"): \(notice.message)"
              )
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
      }
    }
  }

  // MARK: Toolbar

  private var captureButton: some View {
    Group {
      if liveRecording.canStop {
        ToolbarStopMount(
          onStop: {
            Task {
              await liveRecording.stop()
              store.refresh()
            }
          }
        )
        .frame(width: 132, height: 32)
      } else {
        ToolbarRecordMount(
          enabled: canRecord,
          help: "Record \(liveRecording.captureSelection.recordedAudio)",
          onRecord: startRecording
        )
        .frame(width: 104, height: 32)
      }
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

  private var openPackageAction: (() -> Void)? {
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

  private var workspaceNotices: [WorkspaceNotice] {
    var notices = [WorkspaceNotice]()
    if let message = store.errorMessage {
      notices.append(.init(id: "library", message: message, isFailure: true))
    }
    if let message = recoveredSessions.errorMessage,
      recoveredSessions.errorSessionId == nil
    {
      notices.append(.init(id: "playback", message: message, isFailure: true))
    }
    if importedMediaAuthority.phase == .failed,
      let message = importedMediaAuthority.statusMessage
    {
      notices.append(.init(id: "import", message: message, isFailure: true))
    } else if notices.isEmpty, importedMediaAuthority.pendingAudioImport == nil,
      let message = importedMediaAuthority.statusMessage
    {
      notices.append(.init(id: "import", message: message, isFailure: false))
    }
    if let message = transcripts.message {
      notices.append(
        .init(id: "transcripts", message: message, isFailure: transcripts.messageIsFailure))
    }
    if let message = store.editMessage, store.pendingRename == nil {
      notices.append(.init(id: "edit", message: message, isFailure: store.editMessageIsFailure))
    }
    if notices.isEmpty, liveRecording.phase == .saved,
      selectedSessionId == liveRecording.lastSavedSessionId,
      let message = liveRecording.mixdownStatus
    {
      notices.append(.init(id: "mixdown", message: message, isFailure: false))
    }
    return notices
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

  private func requestDeletion(_ session: RuntimeSessionPresentation) {
    guard session.deletionUnavailableReason == nil else { return }
    if recoveredSessions.activePlaybackSessionId == session.sessionId {
      recoveredSessions.stopPlayback()
    }
    Task { await transcripts.requestDeletion(sessionId: session.sessionId) }
  }

  private func copyConversation(_ session: RuntimeSessionPresentation) {
    let title = ConversationIdentityPresentation.title(for: session)
    Task {
      guard
        let copied = try? await transcripts.clipboardText(
          sessionId: session.sessionId, title: title)
      else {
        AccessibilityAnnouncer.post("The conversation could not be copied.")
        return
      }
      ConversationClipboard.copy(copied.text)
      AccessibilityAnnouncer.post("Copied \(title)")
    }
  }

  private func synchronizeSelection(preferCurrentSession: Bool) {
    navigation.synchronize(
      currentSessionId: store.currentSession?.sessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId),
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
  let onRecord: () -> Void
  let onOpenPackage: (() -> Void)?

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
        RecordStartMount(enabled: canRecord, onRecord: onRecord)
          .frame(width: 120, height: 32)
        if let onOpenPackage {
          PortablePackageOpenMount(
            enabled: canImport,
            help: canImport
              ? ImportedMediaAuthorityAdapter.portablePackageHelp
              : ImportedMediaAuthorityAdapter.portablePackageWaitHelp,
            onOpen: onOpenPackage
          )
          .frame(width: 200, height: 32)
        }
      }
      .padding(.top, 6)
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
