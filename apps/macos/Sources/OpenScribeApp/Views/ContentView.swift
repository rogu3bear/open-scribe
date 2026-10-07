import SwiftUI

struct ContentView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var context: ContextScopeModel
  @StateObject private var navigation = MainWorkspaceNavigation()
  @State private var searchQuery = ""

  private var selectedSessionId: String? {
    navigation.selectedSessionId
  }

  private var selectedSessionBinding: Binding<String?> {
    Binding(
      get: { navigation.selectedSessionId },
      set: { selectedSessionId in
        navigation.select(selectedSessionId)
      }
    )
  }

  private var selectedSession: RuntimeSessionPresentation? {
    if store.currentSession?.sessionId == selectedSessionId {
      return store.currentSession
    }
    return store.savedSessions.first { $0.sessionId == selectedSessionId }
  }

  var body: some View {
    NavigationSplitView {
      conversationSidebar
    } detail: {
      selectedWorkspace
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 520)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        captureButton
        RecorderControls(recorder: liveRecording, store: store)
        importButton
        if importedMediaAuthority.canOpenPackages {
          openPackageButton
        }
      }
    }
    .onAppear {
      store.refresh()
      AppTelemetry.runtimeSceneAppeared("primary", session: store.currentSession)
      // Selection is published state. Applying it on the next turn keeps the
      // first library layout from redrawing inside its own appearance pass.
      Task { @MainActor in
        synchronizeSelection(preferCurrentSession: true)
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
    .onChange(of: importedMediaAuthority.importedSessionId) { importedSessionId in
      navigation.acceptImportedConversation(
        importedSessionId,
        savedSessionIds: store.savedSessions.map(\.sessionId)
      )
    }
    .onChange(of: searchQuery) { query in
      transcripts.search(query)
    }
    .confirmationDialog(
      "Move this conversation to Trash?",
      isPresented: Binding(
        get: { transcripts.pendingDeletion != nil },
        set: { presented in
          if !presented { transcripts.cancelDeletion() }
        }
      ),
      presenting: transcripts.pendingDeletion
    ) { _ in
      Button("Move to Trash", role: .destructive) {
        if transcripts.confirmDeletion() {
          store.refresh()
        }
      }
      Button("Cancel", role: .cancel) {
        transcripts.cancelDeletion()
      }
    } message: { inventory in
      Text(SessionDeletionSummary.text(inventory))
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
        if ProcessInfo.processInfo.arguments.contains("--m0-proof-settings") {
          if #available(macOS 14.0, *) {
            SettingsProofTrigger()
          }
        }
      #endif
    }
  }

  private var conversationSidebar: some View {
    List(selection: selectedSessionBinding) {
      if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
        Section("Transcript Matches") {
          if transcripts.searchResults.isEmpty {
            Text("No matching transcript text")
              .foregroundStyle(.secondary)
          }
          ForEach(transcripts.searchResults, id: \.self) { hit in
            Button {
              openSearchHit(hit)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(hit.sessionTitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(hit.effectiveText)
                  .lineLimit(2)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(hit.sessionTitle): \(hit.effectiveText)")
          }
        }
      }

      if let current = store.currentSession {
        Section("Now") {
          if current.lifecycle == "interrupted" {
            ConversationSidebarRow(session: current)
              .tag(current.sessionId)
              .contextMenu {
                Button("Move to Trash…", role: .destructive) {
                  requestDeletion(current)
                }
                .disabled(!liveRecording.canStart)
              }
          } else {
            ConversationSidebarRow(session: current)
              .tag(current.sessionId)
          }
        }
      }

      if !LibraryConversationLists.interrupted(store.savedSessions).isEmpty {
        Section("Interrupted") {
          ForEach(LibraryConversationLists.interrupted(store.savedSessions)) { session in
            ConversationSidebarRow(session: session)
              .tag(session.sessionId)
              .contextMenu {
                Button("Move to Trash…", role: .destructive) {
                  requestDeletion(session)
                }
                .disabled(!liveRecording.canStart)
              }
          }
        }
      }

      Section("Conversations") {
        let saved = LibraryConversationLists.saved(store.savedSessions)
        if saved.isEmpty {
          Text("No saved conversations yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(saved) { session in
            ConversationSidebarRow(session: session)
              .tag(session.sessionId)
              .contextMenu {
                Button("Move to Trash…", role: .destructive) {
                  requestDeletion(session)
                }
                .disabled(!liveRecording.canStart)
              }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search transcripts")
    .onDeleteCommand {
      // Delete (or Edit > Delete) moves the selected saved conversation to
      // Trash through the same confirmation as the context menu.
      guard liveRecording.canStart,
        let session = store.savedSessions.first(where: { $0.sessionId == selectedSessionId })
      else { return }
      requestDeletion(session)
    }
    .navigationTitle("Library")
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    VStack(spacing: 0) {
      statusBanner
      if let selectedSession {
        if selectedSession.sessionId == store.currentSession?.sessionId {
          CompactLiveView(store: store, liveRecording: liveRecording, context: context)
        } else {
          ConversationWorkspaceView(
            session: selectedSession,
            playbackController: recoveredSessions,
            transcripts: transcripts,
            speech: speech,
            loadRecorderEvents: { (try? liveRecording.detail(sessionId: $0).events) ?? [] }
          )
        }
      } else {
        EmptyConversationWorkspace(
          canRecord: MainWorkspaceActions.canRecord(
            liveCanStart: liveRecording.canStart,
            importIsBusy: importedMediaAuthority.isBusy
          ),
          canImport: canImport,
          importIsBusy: importedMediaAuthority.isBusy,
          onRecord: startRecording,
          onImport: importedMediaAuthority.chooseAndImport,
          onOpenPackage: openPackageAction
        )
      }
    }
  }

  @ViewBuilder
  private var statusBanner: some View {
    if !workspaceNotices.isEmpty {
      VStack(spacing: 0) {
        ForEach(workspaceNotices) { notice in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.isFailure ? "exclamationmark.triangle" : "checkmark.circle")
            Text(notice.message)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.callout)
          .foregroundStyle(notice.isFailure ? Color.red : Color.secondary)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(notice.isFailure ? "Problem" : "Status"): \(notice.message)"
          )
        }
      }
      .background(.bar)
    }
  }

  private var captureButton: some View {
    Group {
      if liveRecording.canStop {
        Button("Stop and Save", systemImage: "stop.fill") {
          Task {
            await liveRecording.stop()
            store.refresh()
          }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
      } else {
        Button("Record", systemImage: "record.circle") {
          startRecording()
        }
        .disabled(
          !MainWorkspaceActions.canRecord(
            liveCanStart: liveRecording.canStart,
            importIsBusy: importedMediaAuthority.isBusy
          )
        )
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Record \(liveRecording.captureSelection.recordedAudio)")
      }
    }
  }

  private var importButton: some View {
    Button(
      importedMediaAuthority.isBusy ? "Importing…" : "Import Audio…",
      systemImage: "square.and.arrow.down"
    ) {
      importedMediaAuthority.chooseAndImport()
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
        ? "Open a .openscribe package exported on another Mac as a new conversation"
        : "Wait for the current recording or import to finish before opening a package"
    )
  }

  private var canImport: Bool {
    liveRecording.canStart && !importedMediaAuthority.isBusy
  }

  private var workspaceNotices: [WorkspaceNotice] {
    var notices = [WorkspaceNotice]()
    if let message = liveRecording.errorMessage {
      notices.append(.init(id: "recording", message: message, isFailure: true))
    }
    if let message = store.errorMessage {
      notices.append(.init(id: "library", message: message, isFailure: true))
    }
    if let message = recoveredSessions.errorMessage,
      MainWorkspacePlaybackNotice.shouldPresent(
        errorSessionId: recoveredSessions.errorSessionId,
        selectedSessionId: selectedSessionId
      )
    {
      notices.append(.init(id: "playback", message: message, isFailure: true))
    }
    if importedMediaAuthority.phase == .failed,
      let message = importedMediaAuthority.statusMessage
    {
      notices.append(.init(id: "import", message: message, isFailure: true))
    } else if notices.isEmpty, let message = importedMediaAuthority.statusMessage {
      notices.append(.init(id: "import", message: message, isFailure: false))
    }
    if let message = transcripts.message {
      notices.append(
        .init(id: "transcripts", message: message, isFailure: transcripts.messageIsFailure))
    }
    if notices.isEmpty, liveRecording.phase == .saved,
      selectedSessionId == liveRecording.lastSavedSessionId,
      let message = liveRecording.mixdownStatus
    {
      notices.append(.init(id: "mixdown", message: message, isFailure: false))
    }
    return notices
  }

  private func startRecording() {
    Task {
      await liveRecording.start()
      store.refresh()
      synchronizeSelection(preferCurrentSession: true)
    }
  }

  private func openSearchHit(_ hit: NativeTranscriptSearchHit) {
    navigation.select(hit.sessionId)
    if store.savedSessions.contains(where: { $0.sessionId == hit.sessionId && $0.hasCaptureTimeline }) {
      recoveredSessions.playSynchronized(
        sessionId: hit.sessionId, startNanoseconds: hit.startNanoseconds)
    }
  }

  private func requestDeletion(_ session: RuntimeSessionPresentation) {
    if recoveredSessions.activePlaybackSessionId == session.sessionId {
      recoveredSessions.stopPlayback()
    }
    transcripts.requestDeletion(sessionId: session.sessionId)
  }

  private func synchronizeSelection(preferCurrentSession: Bool) {
    navigation.synchronize(
      currentSessionId: store.currentSession?.sessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId),
      preferCurrentSession: preferCurrentSession
    )
  }
}

private struct WorkspaceNotice: Identifiable {
  let id: String
  let message: String
  let isFailure: Bool
}

@MainActor
final class MainWorkspaceNavigation: ObservableObject {
  @Published private(set) var selectedSessionId: String?
  private(set) var pendingImportedSessionId: String?

  func select(_ sessionId: String?) {
    guard selectedSessionId != sessionId else { return }
    selectedSessionId = sessionId
  }

  func synchronize(
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) {
    let resolved = MainWorkspaceSelection.resolve(
      selectedSessionId: selectedSessionId,
      currentSessionId: currentSessionId,
      savedSessionIds: savedSessionIds,
      preferCurrentSession: preferCurrentSession
    )
    if selectedSessionId != resolved {
      selectedSessionId = resolved
    }
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  func acceptImportedConversation(_ sessionId: String?, savedSessionIds: [String]) {
    pendingImportedSessionId = sessionId
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  private func reconcileImportedConversation(savedSessionIds: [String]) {
    let resolution = MainWorkspaceSelection.reconcileImportedConversation(
      pendingImportedSessionId: pendingImportedSessionId,
      selectedSessionId: selectedSessionId,
      savedSessionIds: savedSessionIds
    )
    if selectedSessionId != resolution.selectedSessionId {
      selectedSessionId = resolution.selectedSessionId
    }
    pendingImportedSessionId = resolution.pendingImportedSessionId
  }
}

enum MainWorkspaceSelection {
  struct ImportedConversationResolution: Equatable {
    let selectedSessionId: String?
    let pendingImportedSessionId: String?
  }

  static func resolve(
    selectedSessionId: String?,
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) -> String? {
    if preferCurrentSession, let currentSessionId {
      return currentSessionId
    }

    let availableSessionIds = Set(savedSessionIds + [currentSessionId].compactMap { $0 })
    if let selectedSessionId, availableSessionIds.contains(selectedSessionId) {
      return selectedSessionId
    }
    return currentSessionId ?? savedSessionIds.first
  }

  static func shouldStopDetachedPlayback(
    activePlaybackSessionId: String?,
    selectedSessionId: String?
  ) -> Bool {
    guard let activePlaybackSessionId else { return false }
    return activePlaybackSessionId != selectedSessionId
  }

  static func reconcileImportedConversation(
    pendingImportedSessionId: String?,
    selectedSessionId: String?,
    savedSessionIds: [String]
  ) -> ImportedConversationResolution {
    guard let pendingImportedSessionId else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: nil
      )
    }
    guard savedSessionIds.contains(pendingImportedSessionId) else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: pendingImportedSessionId
      )
    }
    return ImportedConversationResolution(
      selectedSessionId: pendingImportedSessionId,
      pendingImportedSessionId: nil
    )
  }
}

enum MainWorkspaceActions {
  static func canRecord(liveCanStart: Bool, importIsBusy: Bool) -> Bool {
    liveCanStart && !importIsBusy
  }
}

enum MainWorkspacePlaybackNotice {
  static func shouldPresent(errorSessionId: String?, selectedSessionId: String?) -> Bool {
    errorSessionId == nil || errorSessionId == selectedSessionId
  }
}

enum PlaybackControlAction: Equatable, Sendable {
  case play
  case cancel
  case stop

  static func resolve(isPending: Bool, isPlaying: Bool) -> Self {
    if isPlaying { return .stop }
    if isPending { return .cancel }
    return .play
  }

  var title: String {
    switch self {
    case .play: "Play"
    case .cancel: "Cancel"
    case .stop: "Stop"
    }
  }

  func isEnabled(hasActivePlayback: Bool) -> Bool {
    self != .play || !hasActivePlayback
  }
}

enum ImportedPlaybackEligibility {
  static func canPlay(_ media: RuntimePlayableMediaPresentation) -> Bool {
    media.isPlayable
  }

  static func status(_ media: RuntimePlayableMediaPresentation) -> String {
    return media.statusText
  }
}

enum LibraryConversationLists {
  static func saved(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation] {
    sessions.filter { $0.lifecycle == "ready_for_review" }
  }

  static func interrupted(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation] {
    sessions.filter { $0.lifecycle == "interrupted" }
  }
}

private struct ConversationSidebarRow: View {
  let session: RuntimeSessionPresentation

  private var symbolName: String? {
    if session.isRecording { return "record.circle.fill" }
    if session.needsAttention { return "exclamationmark.triangle" }
    return nil
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let symbolName {
        Image(systemName: symbolName)
          .foregroundStyle(session.isRecording ? Color.red : Color.orange)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(session.title)
          .lineLimit(1)
        Text("\(session.timerText) · \(session.statusText)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.title), \(session.timerText), \(session.statusText)")
  }
}

private struct ConversationWorkspaceView: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var playbackController: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  let loadRecorderEvents: @MainActor (String) -> [NativeRecorderEvent]
  @State private var recorderEvents: [NativeRecorderEvent] = []

  private var recoveredTracks: [RecoveredTrackPresentation] {
    session.recoveredTracks(from: playbackController.sessions)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        if session.needsAttention {
          attentionNotice
        }
        audioSection
        if session.lifecycle == "ready_for_review" {
          TranscriptSection(
            session: session,
            transcripts: transcripts,
            speech: speech,
            canSeek: session.hasCaptureTimeline || session.playableMedia?.isPlayable == true,
            onSeek: { position in
              // Captures seek on the shared timeline; imports within their media.
              if session.hasCaptureTimeline {
                playbackController.playSynchronized(
                  sessionId: session.sessionId, startNanoseconds: position)
              } else {
                playbackController.play(session, startNanoseconds: position)
              }
            }
          )
        }
        if !session.sources.isEmpty {
          sourceSection
        }
        ContextEventsSection(
          detail: transcripts.sessionId == session.sessionId ? transcripts.contextDetail : nil,
          events: transcripts.sessionId == session.sessionId ? transcripts.contextEvents : [],
          canSeek: session.hasCaptureTimeline,
          onSeek: { event in
            // Navigation follows Rust evidence resolution, never the row alone.
            if let start = transcripts.contextEvidenceStart(event) {
              playbackController.playSynchronized(sessionId: session.sessionId, startNanoseconds: start)
            }
          })
        RecorderEventList(events: recorderEvents)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle(session.title)
    .task(id: "\(session.sessionId)|\(session.lifecycle)") {
      recorderEvents = loadRecorderEvents(session.sessionId)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label(session.timerText, systemImage: "clock")
      Text("·")
        .foregroundStyle(.tertiary)
      Text(session.statusText)
    }
    .font(.title3)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel("\(session.title), \(session.timerText), \(session.statusText)")
  }

  private var attentionNotice: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text("This recording needs attention")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text(
          session.interruptionText
            ?? "Open Scribe preserved the audio it could verify. Review each source below."
        )
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
    }
    .foregroundStyle(.orange)
    .accessibilityElement(children: .combine)
  }

  private var audioSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Audio")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      if session.lifecycle == "ready_for_review", session.hasCaptureTimeline {
        let active =
          playbackController.activePlaybackSessionId == session.sessionId
          && playbackController.pendingRecoveredMediaIdentity == nil
          && playbackController.playingRecoveredMediaIdentity == nil
        let mixActive = active && playbackController.activeMixdownSessionId == session.sessionId
        let timelineActive = active && !mixActive
        Button(mixActive ? "Stop stereo mix" : "Play stereo mix") {
          if mixActive {
            playbackController.stopPlayback()
          } else {
            playbackController.playMixdown(sessionId: session.sessionId)
          }
        }
        .disabled(active && !mixActive)
        Text("The mix is made from the saved source tracks and checked before playback.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(timelineActive ? "Stop synchronized playback" : "Play all sources together") {
          if timelineActive {
            playbackController.stopPlayback()
          } else {
            playbackController.playSynchronized(sessionId: session.sessionId)
          }
        }
        .disabled(playbackController.activePlaybackSessionId != nil && !timelineActive)
        Text("Uses the recorded timeline, including source offsets and gaps.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if timelineActive, playbackController.timelineClockAdjustmentNanoseconds > 0 {
          Text(
            "Source clock alignment: up to \(Double(playbackController.timelineClockAdjustmentNanoseconds) / 1_000_000, specifier: "%.1f") ms. All recorded samples are preserved."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if playbackController.errorSessionId == session.sessionId,
          playbackController.errorRecoveredMediaIdentity == nil,
          let message = playbackController.errorMessage
        {
          Text(message).foregroundStyle(.orange)
        }
      }

      if let media = session.playableMedia {
        let canPlay = ImportedPlaybackEligibility.canPlay(media)
        let isPlaying = playbackController.playingSessionId == session.sessionId
        let isPending =
          playbackController.activePlaybackSessionId == session.sessionId && !isPlaying
        let playbackAction = PlaybackControlAction.resolve(
          isPending: isPending,
          isPlaying: isPlaying
        )
        let playbackError =
          playbackController.errorSessionId == session.sessionId
            && playbackController.errorRecoveredMediaIdentity == nil
          ? playbackController.errorMessage : nil
        PlayableAudioRow(
          name: media.sourceDisplayName,
          duration: media.durationText,
          status: isPending
            ? "Verifying local audio"
            : playbackError ?? ImportedPlaybackEligibility.status(media),
          statusIsFailure: playbackError != nil || (media.isPlayable && !canPlay),
          isAvailable: canPlay,
          actionEnabled:
            playbackAction != .play
            || (canPlay
              && playbackAction.isEnabled(
                hasActivePlayback: playbackController.activePlaybackSessionId != nil
              )),
          playbackAction: playbackAction,
          onTogglePlayback: toggleImportedPlayback
        )
      } else if !recoveredTracks.isEmpty {
        ForEach(recoveredTracks) { track in
          let identity = RecoveredPlaybackMediaIdentity(track.playableSession)
          let isPlaying =
            playbackController.playingRecoveredMediaIdentity
            == identity
          let isPending = playbackController.pendingRecoveredMediaIdentity == identity
          let playbackAction = PlaybackControlAction.resolve(
            isPending: isPending,
            isPlaying: isPlaying
          )
          let playbackError =
            playbackController.errorSessionId == session.sessionId
              && playbackController.errorRecoveredMediaIdentity == identity
            ? playbackController.errorMessage : nil
          PlayableAudioRow(
            name: track.source.name,
            duration: track.durationText,
            status: isPending ? "Verifying local audio" : playbackError ?? "Preserved local audio",
            statusIsFailure: playbackError != nil,
            isAvailable: true,
            actionEnabled: playbackAction.isEnabled(
              hasActivePlayback: playbackController.activePlaybackSessionId != nil
            ),
            playbackAction: playbackAction,
            onTogglePlayback: {
              toggleRecoveredPlayback(track.playableSession)
            }
          )
        }
      } else if !session.hasCaptureTimeline {
        Text("No verified playable audio is available.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sources")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(session.sources, id: \.kind) { source in
        HStack(spacing: 8) {
          Image(systemName: source.symbolName)
            .frame(width: 20)
          Text(source.name)
          Spacer()
          Text(source.stateText)
            .foregroundStyle(source.lifecycle == "failed" ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func toggleImportedPlayback() {
    if playbackController.activePlaybackSessionId == session.sessionId {
      playbackController.stopPlayback()
    } else {
      playbackController.play(session)
    }
  }

  private func toggleRecoveredPlayback(_ playableSession: NativeRecoveredPlayableSession) {
    let identity = RecoveredPlaybackMediaIdentity(playableSession)
    if playbackController.pendingRecoveredMediaIdentity == identity
      || playbackController.playingRecoveredMediaIdentity == identity
    {
      playbackController.stopPlayback()
    } else {
      playbackController.play(playableSession)
    }
  }
}

private struct PlayableAudioRow: View {
  let name: String
  let duration: String
  let status: String
  let statusIsFailure: Bool
  let isAvailable: Bool
  let actionEnabled: Bool
  let playbackAction: PlaybackControlAction
  let onTogglePlayback: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.headline)
        Text("\(duration) · \(status)")
          .font(.caption)
          .foregroundStyle(statusIsFailure ? Color.red : Color.secondary)
      }
      Button(playbackAction.title) {
        onTogglePlayback()
      }
      .disabled(!actionEnabled)
      .accessibilityLabel("\(playbackAction.title) \(name)")
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }
}

private struct EmptyConversationWorkspace: View {
  let canRecord: Bool
  let canImport: Bool
  let importIsBusy: Bool
  let onRecord: () -> Void
  let onImport: () -> Void
  let onOpenPackage: (() -> Void)?

  var body: some View {
    VStack(spacing: 16) {
      Text("No conversation is open")
        .font(.title.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Record microphone and computer audio, import local CAF or M4A audio, or open a portable package from another Mac. The source stays on this Mac."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 440)
      HStack {
        Button("Record", systemImage: "record.circle", action: onRecord)
          .disabled(!canRecord)
          .buttonStyle(.borderedProminent)
        Button(importIsBusy ? "Importing…" : "Import Audio…", action: onImport)
          .disabled(!canImport)
        if let onOpenPackage {
          Button("Open Portable Package…", action: onOpenPackage)
            .disabled(!canImport)
        }
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}

#if DEBUG
  @available(macOS 14.0, *)
  private struct SettingsProofTrigger: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear {
          openSettings()
        }
    }
  }
#endif
