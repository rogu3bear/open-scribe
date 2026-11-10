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
  @State private var query = ""
  @FocusState private var isSearchFocused: Bool
  @AppStorage(TranscriptTextScale.storageKey) private var storedTranscriptTextScale =
    TranscriptTextScale.standard.rawValue

  private var transcriptTextScale: TranscriptTextScale {
    TranscriptTextScale.resolve(storedTranscriptTextScale)
  }

  private var textScaleBinding: Binding<String> {
    Binding(
      get: { transcriptTextScale.rawValue },
      set: { storedTranscriptTextScale = TranscriptTextScale.resolve($0).rawValue })
  }

  private var speakerSegments: [NativeTranscriptSegment] {
    transcripts.segments.filter { segment in
      switch filter {
      case .all: true
      case .unassigned: segment.namedSpeakerId == nil
      case .person(let id): segment.namedSpeakerId == id
      }
    }
  }

  var body: some View {
    let segments = TranscriptSearch.matching(speakerSegments, query: query)
    let index = TranscriptPlaybackIndex(
      segments.map {
        TranscriptPlaybackRange(id: $0.id, start: $0.startNanoseconds, end: $0.endNanoseconds)
      })
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      searchControls(resultCount: segments.count)
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
    .onChange(of: query) { value in
      if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        followsPlayback = false
      }
    }
    .onChange(of: transcripts.claimHighlightSegmentId) { id in
      if transcripts.claimEvidenceOpen, let id {
        followsPlayback = false
        onFollowPlayback(id)
      }
    }
  }

  private func searchControls(resultCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: ScribeSpacing.related) {
        Button {
          isSearchFocused = true
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(
          ConversationControlLabels.findShortcut.key,
          modifiers: ConversationControlLabels.findShortcut.modifiers)
        .accessibilityLabel(ConversationControlLabels.findInTranscript)
        TextField(ConversationControlLabels.findInTranscript, text: $query)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .accessibilityLabel(ConversationControlLabels.findInTranscript)
        if !query.isEmpty {
          Button {
            query = ""
            isSearchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel(ConversationControlLabels.clearTranscriptSearch)
        }
      }
      .padding(10)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
      }
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(
          "\(resultCount) matching \(resultCount == 1 ? "passage" : "passages"). Play a timestamp to check the audio."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var peopleControls: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.compact) {
          personPicker
          Spacer(minLength: ScribeSpacing.compact)
          if isPlaybackActive { followControl }
        }
        VStack(alignment: .leading, spacing: ScribeSpacing.related) {
          personPicker
          if isPlaybackActive { followControl }
        }
      }
      if transcripts.namedSpeakers.isEmpty {
        Text("Select a speaker label to name that person.")
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
      Picker(TranscriptTextScale.controlLabel, selection: textScaleBinding) {
        ForEach(TranscriptTextScale.allCases) { scale in
          Text(scale.title).tag(scale.rawValue)
        }
      }
      .pickerStyle(.menu)
      .font(.caption)
      .frame(maxWidth: 280, alignment: .leading)
      .accessibilityLabel(TranscriptTextScale.controlLabel)
      .accessibilityValue(transcriptTextScale.spokenValue)
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
    .accessibilityLabel(ConversationControlLabels.filterByPerson)
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
    return LazyVStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      if segments.isEmpty {
        Text(
          query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No passages are assigned to this person in the selected transcript."
            : "No passages match. Try different words, clear the search, or choose all speakers."
        )
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
    let isDraft = segment.finality == "draft"
    let isCited =
      !isDraft && transcripts.claimEvidenceOpen && transcripts.claimHighlightSegmentId == segment.id
    let presentation = TranscriptPassagePresentation.make(
      speaker: segment.speakerLabel, text: segment.effectiveText, finality: segment.finality,
      corrected: segment.corrected, isPlaying: isPlaying, isCited: isCited, query: query,
      scale: transcriptTextScale)
    return HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.compact) {
      Button(stamp) { onSeek(segment.startNanoseconds) }
        .buttonStyle(.link)
        .font(.caption.monospacedDigit())
        .frame(minWidth: 48, alignment: .leading)
        .disabled(!canSeek)
        .accessibilityLabel(
          ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: canSeek))
      VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
        HStack(spacing: ScribeSpacing.related) {
          if isDraft {
            Text(segment.speakerLabel)
              .font(.subheadline.weight(.semibold))
          } else {
            Button(segment.speakerLabel) { namePassage(segment) }
              .buttonStyle(.borderless)
              .font(.subheadline.weight(.semibold))
              .accessibilityLabel(
                ConversationControlLabels.nameSpeakerAccessibility(
                  stamp: stamp, label: segment.speakerLabel))
          }
          if isDraft {
            Text("Draft")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel(ConversationControlLabels.draftState)
          }
          if isPlaying {
            Label("Playing", systemImage: "speaker.wave.2.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if isCited {
            Label("Cited", systemImage: "text.quote")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Cited evidence")
          }
        }
        VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
          Text(presentation.text)
            .font(transcriptTextScale.passageFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            // Selectable AppKit text otherwise retains its pre-correction value.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(presentation.spoken)
          if segment.corrected {
            DisclosureGroup("Corrected · Show machine reading") {
              Text(segment.verbatimText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .contain)
      }
      .frame(maxWidth: 500, alignment: .leading)
      Spacer(minLength: ScribeSpacing.related)
      if !isDraft {
        Button {
          followsPlayback = false
          onCorrect(segment)
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Correct text")
        .accessibilityLabel(ConversationControlLabels.correctAccessibility(stamp: stamp))
      }
    }
    .padding(.vertical, ScribeSpacing.tight)
    .frame(maxWidth: 660, alignment: .leading)
    .background(
      isCited
        ? Color.accentColor.opacity(0.16)
        : isPlaying ? Color.accentColor.opacity(0.08) : Color.clear)
    .accessibilityElement(children: .contain)
  }

  private func namePassage(_ segment: NativeTranscriptSegment) {
    followsPlayback = false
    transcripts.dismissMessage()
    speakerReview = TranscriptSpeakerPresentation(sessionId: sessionId, subject: .passage(segment))
  }

}
