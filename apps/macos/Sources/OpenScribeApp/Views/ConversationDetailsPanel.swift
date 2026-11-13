import SwiftUI

/// The record behind a conversation, beside the document: what was captured,
/// who took part, every way to hear it, how the transcript was made, the
/// less common exports, interpretation, context, and the recorder's journal.
struct ConversationDetailsPanel: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var playbackController: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  let recorderEvents: [NativeRecorderEvent]
  let reference: String?
  let onEditDetails: () -> Void
  let onSeek: (Int64) -> Void
  let onContextSeek: (NativeContextEvent) -> Void
  @State private var showsRecordingDetails = false

  private var isLoaded: Bool { transcripts.sessionId == session.sessionId }
  private var isSaved: Bool { session.lifecycle == "ready_for_review" }
  private var canSeek: Bool {
    session.hasCaptureTimeline || session.playableMedia?.isPlayable == true
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        about
        if isSaved { people }
        if session.hasCaptureTimeline || session.playableMedia != nil
          || !session.recoveredTracks(from: playbackController.sessions).isEmpty
        {
          section("Audio") {
            ConversationAudioList(
              session: session, playbackController: playbackController, showsMix: true)
          }
        }
        if isSaved {
          TranscriptSection(
            session: session, transcripts: transcripts, speech: speech, scheduler: scheduler,
            canSeek: canSeek, onSeek: onSeek)
          InterpretationSection(transcripts: transcripts)
          if isLoaded, !transcripts.derivedClaims.isEmpty {
            ClaimReviewSection(transcripts: transcripts, canSeek: canSeek, onSeek: onSeek)
          }
        }
        ContextEventsSection(
          detail: isLoaded ? transcripts.contextDetail : nil,
          events: isLoaded ? transcripts.contextEvents : [],
          canSeek: session.hasCaptureTimeline,
          onSeek: onContextSeek)
        let diagnostics = recorderEvents.filter { $0.kind != "marker_added" }
        if !diagnostics.isEmpty {
          DisclosureGroup("Recording journal", isExpanded: $showsRecordingDetails) {
            RecorderEventList(events: diagnostics, heading: "Recording events")
              .padding(.top, ScribeSpacing.compact)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(Interview.meta)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Conversation details")
  }

  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var about: some View {
    section("About") {
      VStack(alignment: .leading, spacing: 6) {
        row("Status", session.statusText, symbol: session.captureStatusSymbolName)
        row("Length", session.timerText)
        if let created = session.createdAt {
          row("Recorded", created.formatted(date: .abbreviated, time: .shortened))
        }
        if isLoaded, let metadata = transcripts.reviewMetadata {
          row(
            "Origin",
            metadata.origin == "import"
              ? "Imported" : metadata.origin == "capture" ? "Recorded on this Mac" : "Conversation")
          if metadata.storedMediaBytes > 0 {
            row(
              "Stored audio",
              ByteCountFormatter.string(
                fromByteCount: Int64(clamping: metadata.storedMediaBytes), countStyle: .file))
          }
        }
        if let reference { row("Reference", reference) }
        if !session.sources.isEmpty {
          Text("Sources")
            .font(Interview.sectionLabel)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
          ForEach(session.sources, id: \.kind) { source in
            HStack(spacing: 8) {
              Image(systemName: source.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
              Text(source.name)
              Spacer()
              Text(source.stateText)
                .foregroundStyle(source.lifecycle == "failed" ? .primary : .secondary)
                .fontWeight(source.lifecycle == "failed" ? .semibold : nil)
            }
            .font(Interview.meta)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }

  private func row(_ label: String, _ value: String, symbol: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 92, alignment: .leading)
      if let symbol {
        Image(systemName: symbol)
          .foregroundStyle(session.needsAttention ? Color.orange : Color.secondary)
      }
      Text(value)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(Interview.meta)
    .accessibilityElement(children: .combine)
  }

  private var people: some View {
    let declaration = isLoaded ? transcripts.contextDetail?.declaration : nil
    let participants = declaration?.participants ?? []
    let topic = declaration?.topic
    return section("People and topic") {
      VStack(alignment: .leading, spacing: 6) {
        if let topic {
          row("Topic", topic)
        }
        if !participants.isEmpty {
          row("Participants", ListFormatter.localizedString(byJoining: participants))
        }
        if topic == nil, participants.isEmpty {
          Text("Add who took part and what it was about. Search and Copy include them.")
            .font(Interview.meta)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button(participants.isEmpty && topic == nil ? "Add Details…" : "Edit Details…") {
          onEditDetails()
        }
        .help("Record who took part and what the conversation was about")
      }
    }
  }
}

/// Every way to hear a conversation: the verified mix, the source tracks on
/// the recorded timeline, an imported file, or preserved single tracks.
struct ConversationAudioList: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var playbackController: RecoveredSessionController
  let showsMix: Bool

  private var recoveredTracks: [RecoveredTrackPresentation] {
    session.recoveredTracks(from: playbackController.sessions)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      if showsMix, session.lifecycle == "ready_for_review", session.hasCaptureTimeline {
        let active =
          playbackController.activePlaybackSessionId == session.sessionId
          && playbackController.pendingRecoveredMediaIdentity == nil
          && playbackController.playingRecoveredMediaIdentity == nil
        let timelineActive = active && playbackController.activeMixdownSessionId == nil
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
        Text(
          "Play uses a mix made from the saved source tracks and checked first. Source Tracks plays the recorded timeline, with its offsets and gaps."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
          .font(Interview.meta.weight(.semibold))
        Text(media.isPlayable ? "Playback uses the imported local audio file." : media.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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
            onTogglePlayback: { toggle(track.playableSession) }
          )
        }
      } else if !session.hasCaptureTimeline {
        Text("No verified playable audio is available.")
          .font(Interview.meta)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func toggle(_ playableSession: NativeRecoveredPlayableSession) {
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
          .font(Interview.meta.weight(.semibold))
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
      Spacer(minLength: 8)
      Button(playbackAction.title) {
        onTogglePlayback()
      }
      .disabled(!actionEnabled)
      .accessibilityLabel(
        ConversationControlLabels.recoveredSegment(
          playbackAction, name: name, segment: segmentReference))
    }
    .padding(.vertical, ScribeSpacing.related)
    .accessibilityElement(children: .contain)
  }
}
