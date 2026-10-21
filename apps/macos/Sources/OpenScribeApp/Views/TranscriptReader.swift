import SwiftUI

private enum TranscriptPersonFilter: Hashable {
  case all
  case unassigned
  case person(String)
}

/// A chronological conversation document. Human names filter the reading;
/// the native renderer supplies the clock. Neither changes source evidence.
struct TranscriptReader: View {
  let sessionId: String
  @ObservedObject var transcripts: TranscriptLibraryModel
  let canSeek: Bool
  let isPlaybackActive: Bool
  let playbackPosition: () -> TranscriptPlaybackPosition?
  let onSeek: (Int64) -> Void
  let onCorrect: (NativeTranscriptSegment) -> Void
  let onFollowPlayback: (String) -> Void
  @State private var filter: TranscriptPersonFilter = .all
  @State private var followsPlayback = true
  @State private var speakerReview: TranscriptSpeakerPresentation?

  private var filteredSegments: [NativeTranscriptSegment] {
    transcripts.segments.filter { segment in
      switch filter {
      case .all: true
      case .unassigned: segment.namedSpeakerId == nil
      case .person(let id): segment.namedSpeakerId == id
      }
    }
  }

  var body: some View {
    let segments = filteredSegments
    let index = TranscriptPlaybackIndex(
      segments.map {
        TranscriptPlaybackRange(id: $0.id, start: $0.startNanoseconds, end: $0.endNanoseconds)
      })
    VStack(alignment: .leading, spacing: 16) {
      peopleControls
      if isPlaybackActive {
        // Only the active reader ticks. No library-wide publisher, frame
        // callback, ASR work, or file decoding runs on this display timer.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
          document(segments, index: index, position: playbackPosition())
        }
      } else {
        document(segments, index: index, position: nil)
      }
    }
    .sheet(item: $speakerReview) { presentation in
      TranscriptSpeakerReview(presentation: presentation, transcripts: transcripts) {
        if speakerReview?.id == presentation.id { speakerReview = nil }
      }
    }
    .onChange(of: transcripts.namedSpeakers) { people in
      if case .person(let id) = filter, !people.contains(where: { $0.id == id }) { filter = .all }
    }
  }

  private var peopleControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          personPicker
          Spacer(minLength: 12)
          followControl
        }
        VStack(alignment: .leading, spacing: 8) {
          personPicker
          followControl
        }
      }
      if transcripts.namedSpeakers.isEmpty {
        Text("Name a passage to identify who is speaking. Names are confirmed by you.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Menu("Edit a person's name…") {
          ForEach(transcripts.namedSpeakers, id: \.id) { person in
            Button(person.label) {
              followsPlayback = false
              transcripts.dismissMessage()
              speakerReview = TranscriptSpeakerPresentation(
                sessionId: sessionId, subject: .person(person))
            }
          }
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .help("To find their passages across the library, search speaker: followed by their name")
      }
    }
  }

  private var personPicker: some View {
    Picker("Show", selection: $filter) {
      Text("All speakers").tag(TranscriptPersonFilter.all)
      Text("Unassigned passages").tag(TranscriptPersonFilter.unassigned)
      ForEach(transcripts.namedSpeakers, id: \.id) { person in
        Text("\(person.label) · \(person.selectedTurns) passages")
          .tag(TranscriptPersonFilter.person(person.id))
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: 320, alignment: .leading)
    .lineLimit(1)
    .accessibilityLabel("Filter transcript by person")
  }

  private var followControl: some View {
    Toggle("Follow playback", isOn: $followsPlayback)
      .toggleStyle(.checkbox)
      .font(.caption)
      .help("Keep the currently playing passage in view. Turn off to read freely.")
  }

  private func document(
    _ segments: [NativeTranscriptSegment], index: TranscriptPlaybackIndex,
    position: TranscriptPlaybackPosition?
  ) -> some View {
    let activeIds =
      position.flatMap { $0.sessionId == sessionId ? $0.nanoseconds : nil }
      .map { index.activeTurnIds(at: $0) } ?? []
    return LazyVStack(alignment: .leading, spacing: 12) {
      if segments.isEmpty {
        Text("No passages are assigned to this person in the selected transcript.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(segments) { segment in
        passage(segment, isPlaying: activeIds.contains(segment.id))
          .id("transcript-\(segment.id)")
      }
    }
    .onAppear {
      if followsPlayback, let id = activeIds.first { onFollowPlayback(id) }
    }
    .onChange(of: activeIds.first) { id in
      if followsPlayback, let id { onFollowPlayback(id) }
    }
    .onChange(of: followsPlayback) { follows in
      if follows, let id = activeIds.first { onFollowPlayback(id) }
    }
  }

  private func passage(_ segment: NativeTranscriptSegment, isPlaying: Bool) -> some View {
    let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      Button(stamp) { onSeek(segment.startNanoseconds) }
        .buttonStyle(.link)
        .font(.caption.monospacedDigit())
        .frame(minWidth: 48, alignment: .leading)
        .disabled(!canSeek)
        .accessibilityLabel(canSeek ? "Play from \(stamp)" : stamp)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Button(segment.speakerLabel) { namePassage(segment) }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Name the speaker at \(stamp): \(segment.speakerLabel)")
          if isPlaying {
            Label("Playing", systemImage: "speaker.wave.2.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(segment.effectiveText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          if segment.corrected {
            Text("Corrected. Machine reading: \(segment.verbatimText)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        // Preserve the existing explicit accessibility projection: selectable
        // AppKit text can otherwise retain its pre-correction value. Keep the
        // speaker button outside this static-text element so it stays usable.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(
          "\(segment.speakerLabel). \(segment.effectiveText)"
            + (isPlaying ? " Playing." : "")
            + (segment.corrected ? " Corrected. Machine reading: \(segment.verbatimText)" : ""))
      }
      .frame(maxWidth: 500, alignment: .leading)
      Spacer(minLength: 8)
      Button {
        followsPlayback = false
        onCorrect(segment)
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Correct text")
      .accessibilityLabel("Correct the text at \(stamp)")
    }
    .padding(.vertical, 4)
    .frame(maxWidth: 660, alignment: .leading)
    .background(isPlaying ? Color.accentColor.opacity(0.08) : Color.clear)
    .accessibilityElement(children: .contain)
  }

  private func namePassage(_ segment: NativeTranscriptSegment) {
    followsPlayback = false
    transcripts.dismissMessage()
    speakerReview = TranscriptSpeakerPresentation(sessionId: sessionId, subject: .passage(segment))
  }
}
