import SwiftUI

struct ContentView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @StateObject private var navigation = MainWorkspaceNavigation()

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
        importButton
      }
    }
    .onAppear {
      store.refresh()
      synchronizeSelection(preferCurrentSession: true)
      AppTelemetry.runtimeSceneAppeared("primary", session: store.currentSession)
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
      if let current = store.currentSession {
        Section("Now") {
          ConversationSidebarRow(session: current, isCurrent: true)
            .tag(current.sessionId)
        }
      }

      Section("Conversations") {
        if store.savedSessions.isEmpty {
          Text("No saved conversations yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.savedSessions) { session in
            ConversationSidebarRow(session: session, isCurrent: false)
              .tag(session.sessionId)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Library")
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    VStack(spacing: 0) {
      statusBanner
      if let selectedSession {
        if selectedSession.sessionId == store.currentSession?.sessionId {
          CompactLiveView(store: store, liveRecording: liveRecording)
        } else {
          ConversationWorkspaceView(
            session: selectedSession,
            playbackController: recoveredSessions
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
          onImport: importedMediaAuthority.chooseAndImport
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
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
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
        .help("Record microphone and computer audio")
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
        ? "Add a supported local CAF recording"
        : "Wait for the current recording action to finish before importing audio"
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
    return notices
  }

  private func startRecording() {
    Task {
      await liveRecording.start()
      store.refresh()
      synchronizeSelection(preferCurrentSession: true)
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
    selectedSessionId = sessionId
  }

  func synchronize(
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) {
    selectedSessionId = MainWorkspaceSelection.resolve(
      selectedSessionId: selectedSessionId,
      currentSessionId: currentSessionId,
      savedSessionIds: savedSessionIds,
      preferCurrentSession: preferCurrentSession
    )
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
    selectedSessionId = resolution.selectedSessionId
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

enum ImportedPlaybackEligibility {
  static func canPlay(_ media: RuntimePlayableMediaPresentation) -> Bool {
    media.isPlayable && media.byteLength <= ImportedPlaybackMemoryPolicy.maximumSnapshotByteLength
  }

  static func status(_ media: RuntimePlayableMediaPresentation) -> String {
    if media.isPlayable
      && media.byteLength > ImportedPlaybackMemoryPolicy.maximumSnapshotByteLength
    {
      return "Too large for safe playback"
    }
    return media.statusText
  }
}

private struct ConversationSidebarRow: View {
  let session: RuntimeSessionPresentation
  let isCurrent: Bool

  private var symbolName: String {
    if isCurrent { return session.isRecording ? "record.circle.fill" : "waveform" }
    if session.needsAttention { return "exclamationmark.triangle" }
    if session.playableMedia != nil { return "waveform.circle" }
    return session.recovered ? "arrow.clockwise.circle" : "waveform.badge.checkmark"
  }

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(session.title)
          .lineLimit(1)
        Text("\(session.timerText) · \(session.statusText)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: symbolName)
        .foregroundStyle(session.needsAttention ? .orange : .secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.title), \(session.timerText), \(session.statusText)")
  }
}

private struct ConversationWorkspaceView: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var playbackController: RecoveredSessionController

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
        if !session.sources.isEmpty {
          sourceSection
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle(session.title)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(session.title)
        .font(.largeTitle.weight(.semibold))
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 8) {
        Label(session.timerText, systemImage: "clock")
        Text("·")
          .foregroundStyle(.tertiary)
        Text(session.statusText)
      }
      .foregroundStyle(.secondary)
    }
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
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      if let media = session.playableMedia {
        let canPlay = ImportedPlaybackEligibility.canPlay(media)
        let playbackError =
          playbackController.errorSessionId == session.sessionId
            && playbackController.errorRecoveredMediaIdentity == nil
          ? playbackController.errorMessage : nil
        PlayableAudioRow(
          name: media.sourceDisplayName,
          duration: media.durationText,
          status: playbackError ?? ImportedPlaybackEligibility.status(media),
          statusIsFailure: playbackError != nil || (media.isPlayable && !canPlay),
          isAvailable: canPlay,
          actionEnabled: canPlay,
          isPlaying: playbackController.playingSessionId == session.sessionId,
          onTogglePlayback: toggleImportedPlayback
        )
      } else if !recoveredTracks.isEmpty {
        ForEach(recoveredTracks) { track in
          let identity = RecoveredPlaybackMediaIdentity(track.playableSession)
          let isPlaying =
            playbackController.playingRecoveredMediaIdentity
            == identity
          let playbackError =
            playbackController.errorSessionId == session.sessionId
              && playbackController.errorRecoveredMediaIdentity == identity
            ? playbackController.errorMessage : nil
          PlayableAudioRow(
            name: track.source.name,
            duration: track.durationText,
            status: playbackError ?? "Preserved local audio",
            statusIsFailure: playbackError != nil,
            isAvailable: true,
            actionEnabled: playbackController.playingSessionId == nil || isPlaying,
            isPlaying: isPlaying,
            onTogglePlayback: {
              toggleRecoveredPlayback(track.playableSession)
            }
          )
        }
      } else {
        Label("No verified playable audio is available.", systemImage: "waveform.slash")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sources")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      ForEach(session.sources, id: \.kind) { source in
        HStack(spacing: 10) {
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
    if playbackController.playingSessionId == session.sessionId {
      playbackController.stopPlayback()
    } else {
      playbackController.play(session)
    }
  }

  private func toggleRecoveredPlayback(_ playableSession: NativeRecoveredPlayableSession) {
    if playbackController.playingRecoveredMediaIdentity
      == RecoveredPlaybackMediaIdentity(playableSession)
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
  let isPlaying: Bool
  let onTogglePlayback: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.headline)
        Text("\(duration) · \(status)")
          .font(.caption)
          .foregroundStyle(statusIsFailure || !isAvailable ? Color.red : Color.secondary)
      }
      Spacer()
      Button(isPlaying ? "Stop" : "Play") {
        onTogglePlayback()
      }
      .disabled(!actionEnabled && !isPlaying)
      .accessibilityLabel(isPlaying ? "Stop \(name)" : "Play \(name)")
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }
}

private struct EmptyConversationWorkspace: View {
  let canRecord: Bool
  let canImport: Bool
  let importIsBusy: Bool
  let onRecord: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform")
        .font(.system(size: 42, weight: .light))
        .foregroundStyle(.secondary)
      Text("Keep a conversation you can return to")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Record microphone and computer audio, or import a supported local CAF recording. Open Scribe keeps the source on this Mac."
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
      }
    }
    .padding(40)
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
