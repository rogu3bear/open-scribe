import SwiftUI

private struct ContextSeekRequest {
  let id = UUID()
  let sessionId: String
  let event: NativeContextEvent
}

struct ConversationWorkspaceView: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var playbackController: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  let reference: String?
  let audioReviewRequest: MainWorkspaceNavigation.AudioReviewRequest?
  let canStartNewRecording: Bool
  let newRecordingUnavailableReason: String
  let onStartNewRecording: () -> Void
  let loadRecorderEvents: @MainActor (String) -> [NativeRecorderEvent]
  @State private var recorderEvents: [NativeRecorderEvent] = []
  @State private var showsAudioDetails = false
  @State private var showsRecordingDetails = false
  @State private var renaming: ConversationMetadataPresentation?
  @State private var editingDetails: ConversationMetadataPresentation?
  @State private var contextSeek: ContextSeekRequest?

  private var recoveredTracks: [RecoveredTrackPresentation] {
    session.recoveredTracks(from: playbackController.sessions)
  }

  private var hasPreservedAudio: Bool {
    session.hasVerifiedPreservedAudio(from: playbackController.sessions)
  }

  var body: some View {
    let title = ConversationIdentityPresentation.title(session.title)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: ScribeSpacing.section) {
          header(title: title)
          if session.needsAttention {
            attentionNotice {
              showsAudioDetails = true
              proxy.scrollTo("audio-details", anchor: .top)
            }
            sourceSection
          }
          audioSection
          if session.hasCaptureTimeline || session.playableMedia != nil || !recoveredTracks.isEmpty
          {
            DisclosureGroup("Audio Details", isExpanded: $showsAudioDetails) {
              VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
                if !session.needsAttention, !session.sources.isEmpty { sourceSection }
                audioAlternatives
              }
              .padding(.top, ScribeSpacing.compact)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("audio-details")
          }
          if session.lifecycle == "ready_for_review" {
            TranscriptSection(
              session: session,
              transcripts: transcripts,
              speech: speech,
              scheduler: scheduler,
              canSeek: session.hasCaptureTimeline || session.playableMedia?.isPlayable == true,
              onSeek: { position in
                // Captures seek on the shared timeline; imports within their media.
                if session.hasCaptureTimeline {
                  playbackController.playSynchronized(
                    sessionId: session.sessionId, startNanoseconds: position)
                } else {
                  playbackController.play(session, startNanoseconds: position)
                }
              },
              isPlaybackActive: playbackController.canFollowTranscriptPlayback(
                sessionId: session.sessionId),
              playbackPosition: {
                playbackController.transcriptPlaybackPosition(sessionId: session.sessionId)
              },
              onFollowPlayback: { id in proxy.scrollTo("transcript-\(id)", anchor: .center) }
            )
          }
          if session.lifecycle == "ready_for_review" {
            conversationDetails
          }
          ContextEventsSection(
            detail: transcripts.sessionId == session.sessionId ? transcripts.contextDetail : nil,
            events: transcripts.sessionId == session.sessionId ? transcripts.contextEvents : [],
            canSeek: session.hasCaptureTimeline,
            onSeek: { event in
              contextSeek = ContextSeekRequest(sessionId: session.sessionId, event: event)
            })
          RecorderEventList(
            events: recorderEvents.filter { $0.kind == "marker_added" }, heading: "Markers"
          )
          let diagnostics = recorderEvents.filter { $0.kind != "marker_added" }
          if !diagnostics.isEmpty {
            DisclosureGroup("Recording Details", isExpanded: $showsRecordingDetails) {
              RecorderEventList(events: diagnostics, heading: "Recording events")
                .padding(.top, ScribeSpacing.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(ScribeSpacing.section)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .task(id: audioReviewRequest) {
        guard audioReviewRequest?.sessionId == session.sessionId, hasPreservedAudio else { return }
        showsAudioDetails = true
        proxy.scrollTo("audio-details", anchor: .top)
      }
    }
    .navigationTitle(title)
    .task(id: "\(session.sessionId)|\(contextSeek?.id.uuidString ?? "")") {
      guard let request = contextSeek, request.sessionId == session.sessionId else { return }
      // The view task is cancelled on replacement or disappearance, including
      // navigation to a live/interrupted view that does not load a transcript.
      if let start = await transcripts.contextEvidenceStart(request.event, in: request.sessionId),
        !Task.isCancelled, contextSeek?.id == request.id
      {
        playbackController.playSynchronized(sessionId: request.sessionId, startNanoseconds: start)
      }
    }
    .task(id: "\(session.sessionId)|\(session.lifecycle)") {
      recorderEvents = loadRecorderEvents(session.sessionId)
    }
    .sheet(item: $renaming) { presentation in
      ConversationRenameSheet(session: presentation.session, store: store) {
        presentation.close(&renaming)
      }
    }
    .sheet(item: $editingDetails) { presentation in
      ConversationDetailsSheet(
        session: presentation.session,
        declaration: transcripts.sessionId == presentation.session.sessionId
          ? transcripts.contextDetail?.declaration : nil,
        store: store,
        onSaved: {
          Task { await transcripts.reloadAfterDetailsSave(session: presentation.session) }
        },
        onClose: { presentation.close(&editingDetails) })
    }
  }

  private func header(title: String) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.related) {
        Text(title)
          .font(.title.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityAddTraits(.isHeader)
          .accessibilityLabel(title)
        Button {
          renaming = ConversationMetadataPresentation(session: session)
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Rename this conversation")
        .accessibilityLabel("Rename conversation")
      }
      HStack(spacing: ScribeSpacing.related) {
        Label {
          Text(session.statusText)
            .foregroundStyle(session.needsAttention ? Color.primary : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: session.captureStatusSymbolName)
            .foregroundStyle(session.needsAttention ? Color.orange : Color.secondary)
        }
        Text("·")
        Text(session.timerText).monospacedDigit()
        if let reference {
          Text("·")
          Text(reference).monospaced()
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      if transcripts.sessionId == session.sessionId, let metadata = transcripts.reviewMetadata {
        if metadata.addedAtMs > 0 {
          Text(
            Date(timeIntervalSince1970: Double(metadata.addedAtMs) / 1_000)
              .formatted(date: .abbreviated, time: .shortened)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func reviewMetadataLine(_ metadata: NativeConversationReviewMetadata) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
      HStack(spacing: ScribeSpacing.related) {
        Text(
          metadata.origin == "import"
            ? "Imported" : metadata.origin == "capture" ? "Capture" : "Conversation")
        if metadata.storedMediaBytes > 0 {
          Text("·")
          Text(
            ByteCountFormatter.string(
              fromByteCount: Int64(clamping: metadata.storedMediaBytes), countStyle: .file))
        }
      }
      .accessibilityElement(children: .combine)
      if !metadata.sourceNames.isEmpty {
        Text(metadata.sourceNames.joined(separator: " · "))
          .textSelection(.enabled)
          .lineLimit(2)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  /// Who took part and what it was about, with one place to change them.
  private var conversationDetails: some View {
    let declaration =
      transcripts.sessionId == session.sessionId ? transcripts.contextDetail?.declaration : nil
    let participants = declaration?.participants ?? []
    let topic = declaration?.topic
    return DisclosureGroup("Conversation details") {
      VStack(alignment: .leading, spacing: ScribeSpacing.related) {
        HStack(alignment: .firstTextBaseline) {
          Spacer()
          Button(participants.isEmpty && topic == nil ? "Add Details…" : "Edit Details…") {
            store.dismissEditMessage()
            editingDetails = ConversationMetadataPresentation(session: session)
          }
          .buttonStyle(.borderless)
          .help("Record who took part and what the conversation was about")
        }
        if let metadata = transcripts.reviewMetadata, transcripts.sessionId == session.sessionId {
          reviewMetadataLine(metadata)
        }
        if let topic {
          Text("Topic: \(topic)")
            .textSelection(.enabled)
        }
        if !participants.isEmpty {
          Text("Participants: \(ListFormatter.localizedString(byJoining: participants))")
            .textSelection(.enabled)
        }
      }
      .padding(.top, ScribeSpacing.related)
    }
    .accessibilityElement(children: .contain)
  }

  private func attentionNotice(onReview: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      CaptureIssueLabel(
        message: session.interruptionText
          ?? "Open Scribe preserved the audio it could verify. Review each source below.")
      if hasPreservedAudio {
        Button("Review Preserved Audio", systemImage: "waveform", action: onReview)
      }
      if session.lifecycle == "interrupted" {
        if !hasPreservedAudio {
          Text(
            playbackController.phase == .scanning
              ? "Checking for preserved local audio…"
              : playbackController.phase == .failed
                ? "Preserved audio could not be checked. Review the recovery error before continuing."
                : "No verified playable audio is available for this conversation."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if canStartNewRecording {
          Button("Start New Recording", systemImage: "record.circle", action: onStartNewRecording)
        } else {
          Text(newRecordingUnavailableReason)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .buttonStyle(.bordered)
  }

  @ViewBuilder
  private var audioSection: some View {
    if session.lifecycle == "ready_for_review", session.hasCaptureTimeline {
      let active = playbackController.activePlaybackSessionId == session.sessionId
      let action = PlaybackControlAction.resolve(
        isPending: active && playbackController.playingSessionId != session.sessionId,
        isPlaying: active && playbackController.playingSessionId == session.sessionId
      )
      VStack(alignment: .leading, spacing: ScribeSpacing.related) {
        primaryAudioButton(
          action, isEnabled: active || playbackController.activePlaybackSessionId == nil
        ) {
          if action == .play {
            playbackController.playMixdown(sessionId: session.sessionId)
          } else {
            playbackController.stopPlayback()
          }
        }
        if active && action == .cancel {
          Text("Verifying local audio…").foregroundStyle(.secondary)
        }
        if playbackController.errorSessionId == session.sessionId,
          playbackController.errorRecoveredMediaIdentity == nil,
          let message = playbackController.errorMessage
        {
          CaptureIssueLabel(message: message, isFailure: true)
          Button("Review Audio Details") { showsAudioDetails = true }
        }
      }
    } else if session.playableMedia != nil {
      importedAudioRow
    }
  }

  private var audioAlternatives: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      if session.lifecycle == "ready_for_review", session.hasCaptureTimeline {
        let active =
          playbackController.activePlaybackSessionId == session.sessionId
          && playbackController.pendingRecoveredMediaIdentity == nil
          && playbackController.playingRecoveredMediaIdentity == nil
        let timelineActive = active && playbackController.activeMixdownSessionId == nil
        Text("The mix is made from the saved source tracks and checked before playback.")
          .font(.caption)
          .foregroundStyle(.secondary)
        let action = PlaybackControlAction.resolve(
          isPending: timelineActive && playbackController.playingSessionId != session.sessionId,
          isPlaying: timelineActive && playbackController.playingSessionId == session.sessionId
        )
        Button(action == .play ? "Play Source Tracks" : "\(action.title) Source Tracks") {
          if action != .play {
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
      }

      if let media = session.playableMedia {
        Text(media.sourceDisplayName)
          .font(.headline)
        Text("Playback uses the imported local audio file.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if !recoveredTracks.isEmpty {
        let references = ShortIdentityReference.references(for: recoveredTracks.map(\.id))
        ForEach(recoveredTracks) { track in
          let identity = RecoveredPlaybackMediaIdentity(track.playableSession)
          let isPlaying = playbackController.playingRecoveredMediaIdentity == identity
          let isPending = playbackController.pendingRecoveredMediaIdentity == identity
          let action = PlaybackControlAction.resolve(isPending: isPending, isPlaying: isPlaying)
          let error =
            playbackController.errorSessionId == session.sessionId
              && playbackController.errorRecoveredMediaIdentity == identity
            ? playbackController.errorMessage : nil
          PlayableAudioRow(
            name: track.source.name, duration: track.durationText,
            segmentReference: references[track.id] ?? track.id,
            status: isPending ? "Verifying local audio" : error ?? "Preserved local audio",
            statusIsFailure: error != nil,
            actionEnabled: action.isEnabled(
              hasActivePlayback: playbackController.activePlaybackSessionId != nil),
            playbackAction: action,
            onTogglePlayback: { toggleRecoveredPlayback(track.playableSession) }
          )
        }
      } else if !session.hasCaptureTimeline {
        Text("No verified playable audio is available.").foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var importedAudioRow: some View {
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
      VStack(alignment: .leading, spacing: ScribeSpacing.related) {
        primaryAudioButton(
          playbackAction,
          isEnabled: playbackAction != .play
            || (canPlay
              && playbackAction.isEnabled(
                hasActivePlayback: playbackController.activePlaybackSessionId != nil)),
          onToggle: toggleImportedPlayback
        )
        if isPending {
          Text("Verifying local audio…").foregroundStyle(.secondary)
        } else if let playbackError {
          CaptureIssueLabel(message: playbackError, isFailure: true)
        } else if !canPlay {
          Text(ImportedPlaybackEligibility.status(media))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func primaryAudioButton(
    _ action: PlaybackControlAction, isEnabled: Bool, onToggle: @escaping () -> Void
  ) -> some View {
    Button(action.title, systemImage: action == .play ? "play.fill" : "stop.fill", action: onToggle)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .font(.headline)
      .disabled(!isEnabled)
      .accessibilityLabel("\(action.title) conversation audio")
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      Text("Sources")
        .scribeSectionHeading()
      ForEach(session.sources, id: \.kind) { source in
        HStack(spacing: ScribeSpacing.related) {
          Image(systemName: source.symbolName)
            .frame(width: 20)
          Text(source.name)
          Spacer()
          Text(source.stateText)
            .foregroundStyle(source.lifecycle == "failed" ? .primary : .secondary)
            .fontWeight(source.lifecycle == "failed" ? .semibold : nil)
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
  let segmentReference: String
  let status: String
  let statusIsFailure: Bool
  let actionEnabled: Bool
  let playbackAction: PlaybackControlAction
  let onTogglePlayback: () -> Void

  var body: some View {
    HStack(spacing: ScribeSpacing.compact) {
      VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
        Text(name)
          .font(.headline)
        Text("Segment \(segmentReference)")
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
        if statusIsFailure {
          CaptureIssueLabel(message: "\(duration) · \(status)", isFailure: true)
            .font(.caption)
        } else {
          Text("\(duration) · \(status)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button(playbackAction.title) {
        onTogglePlayback()
      }
      .disabled(!actionEnabled)
      .accessibilityLabel("\(playbackAction.title) \(name), segment \(segmentReference)")
    }
    .padding(.vertical, ScribeSpacing.related)
    .accessibilityElement(children: .contain)
  }
}
